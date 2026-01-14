/*
 * fcitx5-stt: Speech-to-Text Input Method Engine for Fcitx5
 *
 * This is a thin shim that spawns the stt-stream Rust binary and
 * bridges its JSON events to Fcitx5's input method API.
 *
 * Modes:
 * - Oneshot: Record until silence, commit, reset
 * - Continuous: Always listen, commit on silence
 * - Manual: Start/stop via hotkey
 *
 * UX:
 * - Partial text shown as preedit (underlined)
 * - Final text committed on stop/silence
 * - Escape cancels without committing
 * - Enter accepts current preedit
 */

#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/utf8.h>

#include <memory>
#include <string>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <cstring>
#include <sstream>

#include "config.h"

namespace {

FCITX_DEFINE_LOG_CATEGORY(stt_log, "stt");
#define STT_DEBUG() FCITX_LOGC(stt_log, Debug)
#define STT_INFO() FCITX_LOGC(stt_log, Info)
#define STT_WARN() FCITX_LOGC(stt_log, Warn)
#define STT_ERROR() FCITX_LOGC(stt_log, Error)

// Operating modes
enum class SttMode {
    Oneshot,
    Continuous,
    Manual
};

// Simple JSON parsing (we only need a few fields)
struct JsonEvent {
    std::string type;
    std::string text;
    std::string message;

    static JsonEvent parse(const std::string& line) {
        JsonEvent ev;
        // Very basic JSON parsing - find "type" and "text" fields
        auto findValue = [&line](const std::string& key) -> std::string {
            std::string search = "\"" + key + "\":\"";
            auto pos = line.find(search);
            if (pos == std::string::npos) return "";
            pos += search.length();
            auto end = line.find("\"", pos);
            if (end == std::string::npos) return "";
            return line.substr(pos, end - pos);
        };

        ev.type = findValue("type");
        ev.text = findValue("text");
        ev.message = findValue("message");
        return ev;
    }
};

} // anonymous namespace

class SttEngine;

class SttState : public fcitx::InputContextProperty {
public:
    SttState(SttEngine* engine, fcitx::InputContext* ic)
        : engine_(engine), ic_(ic) {}

    void setPreedit(const std::string& text);
    void commit(const std::string& text);
    void clear();

    bool isRecording() const { return recording_; }
    void setRecording(bool r) { recording_ = r; }

    const std::string& preeditText() const { return preedit_; }

private:
    SttEngine* engine_;
    fcitx::InputContext* ic_;
    std::string preedit_;
    bool recording_ = false;
};

class SttEngine : public fcitx::InputMethodEngineV2 {
public:
    SttEngine(fcitx::Instance* instance);
    ~SttEngine() override;

    // InputMethodEngine interface
    void activate(const fcitx::InputMethodEntry& entry,
                  fcitx::InputContextEvent& event) override;
    void deactivate(const fcitx::InputMethodEntry& entry,
                    fcitx::InputContextEvent& event) override;
    void keyEvent(const fcitx::InputMethodEntry& entry,
                  fcitx::KeyEvent& keyEvent) override;
    void reset(const fcitx::InputMethodEntry& entry,
               fcitx::InputContextEvent& event) override;

    // List input methods this engine provides
    std::vector<fcitx::InputMethodEntry> listInputMethods() override {
        std::vector<fcitx::InputMethodEntry> result;
        result.emplace_back(
            "stt",           // unique name
            _("Speech to Text"),  // display name
            "*",             // language (any)
            "stt"            // addon name
        );
        return result;
    }

    fcitx::Instance* instance() { return instance_; }

    // Process management
    void startProcess();
    void stopProcess();
    void sendCommand(const std::string& cmd);

    // Mode
    SttMode mode() const { return mode_; }
    void setMode(SttMode m);
    void cycleMode();

private:
    void onProcessOutput();
    void handleEvent(const JsonEvent& ev);

    fcitx::Instance* instance_;
    fcitx::FactoryFor<SttState> factory_;

    // Process state
    pid_t childPid_ = -1;
    int stdinFd_ = -1;
    int stdoutFd_ = -1;
    std::unique_ptr<fcitx::EventSourceIO> ioEvent_;
    std::string readBuffer_;

    // Mode
    SttMode mode_ = SttMode::Oneshot;

    // Current state
    bool ready_ = false;
    fcitx::InputContext* activeIc_ = nullptr;
};

// SttState implementation
void SttState::setPreedit(const std::string& text) {
    preedit_ = text;
    if (ic_->hasFocus()) {
        fcitx::Text preeditText;
        preeditText.append(text, fcitx::TextFormatFlag::Underline);
        preeditText.setCursor(text.length());
        ic_->inputPanel().setClientPreedit(preeditText);
        ic_->updatePreedit();
    }
}

void SttState::commit(const std::string& text) {
    if (!text.empty() && ic_->hasFocus()) {
        ic_->commitString(text);
    }
    clear();
}

void SttState::clear() {
    preedit_.clear();
    if (ic_->hasFocus()) {
        ic_->inputPanel().reset();
        ic_->updatePreedit();
        ic_->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }
}

// SttEngine implementation
SttEngine::SttEngine(fcitx::Instance* instance)
    : instance_(instance),
      factory_([this](fcitx::InputContext& ic) {
          return new SttState(this, &ic);
      }) {
    instance_->inputContextManager().registerProperty("sttState", &factory_);
    STT_INFO() << "SttEngine initialized";
}

SttEngine::~SttEngine() {
    stopProcess();
}

void SttEngine::activate(const fcitx::InputMethodEntry& entry,
                         fcitx::InputContextEvent& event) {
    FCITX_UNUSED(entry);
    auto* ic = event.inputContext();
    activeIc_ = ic;

    STT_INFO() << "STT activated";

    // Start the backend process if not running
    if (childPid_ < 0) {
        startProcess();
    }

    // In continuous mode, start recording automatically
    if (mode_ == SttMode::Continuous && ready_) {
        sendCommand("start");
        auto* state = ic->propertyFor(&factory_);
        state->setRecording(true);
    }
}

void SttEngine::deactivate(const fcitx::InputMethodEntry& entry,
                           fcitx::InputContextEvent& event) {
    FCITX_UNUSED(entry);
    auto* ic = event.inputContext();
    auto* state = ic->propertyFor(&factory_);

    // Stop recording if active
    if (state->isRecording()) {
        sendCommand("cancel");
        state->setRecording(false);
    }
    state->clear();

    activeIc_ = nullptr;
    STT_INFO() << "STT deactivated";
}

void SttEngine::keyEvent(const fcitx::InputMethodEntry& entry,
                         fcitx::KeyEvent& keyEvent) {
    FCITX_UNUSED(entry);
    auto* ic = keyEvent.inputContext();
    auto* state = ic->propertyFor(&factory_);

    // Handle special keys
    if (keyEvent.isRelease()) {
        return;
    }

    auto key = keyEvent.key();

    // Escape: cancel recording/preedit
    if (key.check(FcitxKey_Escape)) {
        if (state->isRecording() || !state->preeditText().empty()) {
            sendCommand("cancel");
            state->setRecording(false);
            state->clear();
            keyEvent.filterAndAccept();
            return;
        }
    }

    // Enter/Return: accept preedit
    if (key.check(FcitxKey_Return) || key.check(FcitxKey_KP_Enter)) {
        if (!state->preeditText().empty()) {
            state->commit(state->preeditText());
            sendCommand("cancel");
            state->setRecording(false);
            keyEvent.filterAndAccept();
            return;
        }
    }

    // Space or Ctrl+R: toggle recording (in manual mode)
    if (mode_ == SttMode::Manual) {
        if (key.check(FcitxKey_space, fcitx::KeyState::Ctrl) ||
            key.check(FcitxKey_r, fcitx::KeyState::Ctrl)) {
            if (state->isRecording()) {
                sendCommand("stop");
                state->setRecording(false);
            } else {
                state->clear();
                sendCommand("start");
                state->setRecording(true);
            }
            keyEvent.filterAndAccept();
            return;
        }
    }

    // Ctrl+M: cycle mode
    if (key.check(FcitxKey_m, fcitx::KeyState::Ctrl)) {
        cycleMode();
        keyEvent.filterAndAccept();
        return;
    }

    // In recording state, absorb most keys
    if (state->isRecording()) {
        keyEvent.filterAndAccept();
        return;
    }
}

void SttEngine::reset(const fcitx::InputMethodEntry& entry,
                      fcitx::InputContextEvent& event) {
    FCITX_UNUSED(entry);
    auto* ic = event.inputContext();
    auto* state = ic->propertyFor(&factory_);
    state->clear();
}

void SttEngine::startProcess() {
    if (childPid_ > 0) {
        return; // Already running
    }

    int stdinPipe[2];
    int stdoutPipe[2];

    if (pipe(stdinPipe) < 0 || pipe(stdoutPipe) < 0) {
        STT_ERROR() << "Failed to create pipes";
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        STT_ERROR() << "Failed to fork";
        close(stdinPipe[0]);
        close(stdinPipe[1]);
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        return;
    }

    if (pid == 0) {
        // Child process
        close(stdinPipe[1]);
        close(stdoutPipe[0]);

        dup2(stdinPipe[0], STDIN_FILENO);
        dup2(stdoutPipe[1], STDOUT_FILENO);

        close(stdinPipe[0]);
        close(stdoutPipe[1]);

        // Determine mode string
        const char* modeStr = "manual";
        switch (mode_) {
            case SttMode::Oneshot: modeStr = "oneshot"; break;
            case SttMode::Continuous: modeStr = "continuous"; break;
            case SttMode::Manual: modeStr = "manual"; break;
        }

        execlp(STT_STREAM_PATH, "stt-stream", "--mode", modeStr, nullptr);
        _exit(127);
    }

    // Parent process
    close(stdinPipe[0]);
    close(stdoutPipe[1]);

    childPid_ = pid;
    stdinFd_ = stdinPipe[1];
    stdoutFd_ = stdoutPipe[0];

    // Set stdout non-blocking
    int flags = fcntl(stdoutFd_, F_GETFL, 0);
    fcntl(stdoutFd_, F_SETFL, flags | O_NONBLOCK);

    // Watch stdout for events
    ioEvent_ = instance_->eventLoop().addIOEvent(
        stdoutFd_,
        fcitx::IOEventFlag::In,
        [this](fcitx::EventSourceIO*, int, fcitx::IOEventFlags) {
            onProcessOutput();
            return true;
        }
    );

    STT_INFO() << "Started stt-stream process (pid=" << childPid_ << ")";
}

void SttEngine::stopProcess() {
    if (childPid_ < 0) {
        return;
    }

    ioEvent_.reset();

    sendCommand("shutdown");
    close(stdinFd_);
    close(stdoutFd_);

    // Wait for child to exit
    int status;
    waitpid(childPid_, &status, 0);

    stdinFd_ = -1;
    stdoutFd_ = -1;
    childPid_ = -1;
    ready_ = false;

    STT_INFO() << "Stopped stt-stream process";
}

void SttEngine::sendCommand(const std::string& cmd) {
    if (stdinFd_ < 0) {
        return;
    }

    std::string line = cmd + "\n";
    write(stdinFd_, line.c_str(), line.length());
}

void SttEngine::onProcessOutput() {
    char buf[4096];
    ssize_t n;

    while ((n = read(stdoutFd_, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        readBuffer_ += buf;

        // Process complete lines
        size_t pos;
        while ((pos = readBuffer_.find('\n')) != std::string::npos) {
            std::string line = readBuffer_.substr(0, pos);
            readBuffer_ = readBuffer_.substr(pos + 1);

            if (!line.empty()) {
                auto ev = JsonEvent::parse(line);
                handleEvent(ev);
            }
        }
    }
}

void SttEngine::handleEvent(const JsonEvent& ev) {
    STT_DEBUG() << "Event: type=" << ev.type << " text=" << ev.text;

    if (ev.type == "ready") {
        ready_ = true;
        STT_INFO() << "stt-stream ready";
    } else if (ev.type == "recording_started") {
        // Update UI to show recording state
        if (activeIc_) {
            auto* state = activeIc_->propertyFor(&factory_);
            state->setRecording(true);
        }
    } else if (ev.type == "recording_stopped") {
        if (activeIc_) {
            auto* state = activeIc_->propertyFor(&factory_);
            state->setRecording(false);
        }
    } else if (ev.type == "partial") {
        if (activeIc_) {
            auto* state = activeIc_->propertyFor(&factory_);
            state->setPreedit(ev.text);
        }
    } else if (ev.type == "final") {
        if (activeIc_) {
            auto* state = activeIc_->propertyFor(&factory_);
            state->commit(ev.text);
            state->setRecording(false);

            // In oneshot mode, we're done
            // In continuous mode, keep listening
            if (mode_ == SttMode::Continuous && ready_) {
                sendCommand("start");
                state->setRecording(true);
            }
        }
    } else if (ev.type == "error") {
        STT_ERROR() << "stt-stream error: " << ev.message;
    } else if (ev.type == "shutdown") {
        ready_ = false;
    }
}

void SttEngine::setMode(SttMode m) {
    if (mode_ == m) return;

    mode_ = m;

    // Notify the backend
    const char* modeStr = "manual";
    switch (m) {
        case SttMode::Oneshot: modeStr = "oneshot"; break;
        case SttMode::Continuous: modeStr = "continuous"; break;
        case SttMode::Manual: modeStr = "manual"; break;
    }

    std::string cmd = "{\"cmd\":\"set_mode\",\"mode\":\"";
    cmd += modeStr;
    cmd += "\"}";
    sendCommand(cmd);

    STT_INFO() << "Mode changed to: " << modeStr;
}

void SttEngine::cycleMode() {
    switch (mode_) {
        case SttMode::Manual:
            setMode(SttMode::Oneshot);
            break;
        case SttMode::Oneshot:
            setMode(SttMode::Continuous);
            break;
        case SttMode::Continuous:
            setMode(SttMode::Manual);
            break;
    }
}

// Addon factory
class SttEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance* create(fcitx::AddonManager* manager) override {
        return new SttEngine(manager->instance());
    }
};

FCITX_ADDON_FACTORY(SttEngineFactory);
