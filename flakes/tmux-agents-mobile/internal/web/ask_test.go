package web

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
)

func TestAskPlanAnswersAllQuestions(t *testing.T) {
	custom := "  Alternate\r\nbackend  "
	questions := []transcript.AskQuestion{
		{ID: "single", Options: []transcript.AskOption{{Label: "A"}, {Label: "B"}}},
		{ID: "multi", Multi: true, Options: []transcript.AskOption{{Label: "X"}, {Label: "Y"}, {Label: "Z"}}},
		{ID: "custom", Options: []transcript.AskOption{}},
		{ID: "empty", Multi: true, Options: []transcript.AskOption{}},
	}
	_, answers, err := askPlan(questions, []askAnswerBody{
		{ID: "single", SelectedOptions: []string{"B"}},
		{ID: "multi", SelectedOptions: []string{"X", "Z"}, CustomInput: &custom},
		{ID: "custom", CustomInput: &custom},
		{ID: "empty"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(answers[0].Selected, []int{1}) || !reflect.DeepEqual(answers[1].Selected, []int{0, 2}) || answers[1].Custom != "Alternate\nbackend" || !answers[2].HasCustom || answers[3].HasCustom || len(answers[3].Selected) != 0 {
		t.Fatalf("incorrect answers: %+v", answers)
	}
}

func TestAskPlanRejectsAmbiguousOrStaleAnswers(t *testing.T) {
	custom := "other"
	questions := []transcript.AskQuestion{{ID: "q", Options: []transcript.AskOption{{Label: "A"}, {Label: "B"}}}}
	for _, answers := range [][]askAnswerBody{
		nil,
		{{ID: "old", SelectedOptions: []string{"A"}}},
		{{ID: "q"}},
		{{ID: "q", SelectedOptions: []string{"unknown"}}},
		{{ID: "q", SelectedOptions: []string{"A", "A"}}},
		{{ID: "q", SelectedOptions: []string{"A", "B"}}},
		{{ID: "q", SelectedOptions: []string{"A"}, CustomInput: &custom}},
	} {
		if _, _, err := askPlan(questions, answers); err == nil {
			t.Fatalf("accepted ambiguous answers: %+v", answers)
		}
	}
}

func TestAskRejectsTerminalEscapeInCustomAnswer(t *testing.T) {
	for _, text := range []string{"answer\x1b[201~\r", "answer\x00", "answer\x03"} {
		if _, err := customAnswer(text); err == nil {
			t.Fatalf("accepted terminal control: %q", text)
		}
	}
}

func TestAskPendingRejectsSettledCall(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	body := `{"type":"session","id":"s"}
{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"call","name":"ask","arguments":{"questions":[{"id":"q","question":"Which?","options":[{"label":"A"}]}]}}]}}
`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	sess, err := transcript.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	pending := askPending{r: sess, id: "call", at: -1}
	if _, err := pending.running(); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.WriteString(`{"type":"message","id":"result","parentId":"a","message":{"role":"toolResult","toolCallId":"call","toolName":"ask","content":[{"type":"text","text":"A"}]}}
`)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pending.running(); !errors.Is(err, errAskGone) {
		t.Fatalf("settled call still answerable: %v", err)
	}
}
