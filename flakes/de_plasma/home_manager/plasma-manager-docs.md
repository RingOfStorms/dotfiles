
Appendix A. Plasma-Manager Options
Prev 	 	 
Appendix A. Plasma-Manager Options
programs.elisa.enable
Whether to enable the configuration module for Elisa, KDE’s music player.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.package
The elisa package to use. Use pkgs.libsForQt5.elisa for Plasma 5 or pkgs.kdePackages.elisa for Plasma 6. You can also set this to null if you’re using a system-wide installation of Elisa on NixOS.

Type: null or package

Default: pkgs.kdePackages.elisa

Example: pkgs.libsForQt5.elisa

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.colorScheme
The colour scheme of the UI. Leave this setting at null in order to not override the systems default scheme for for this application.

Type: null or string

Default: null

Example: "Krita dark orange"

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.defaultFilesViewPath
The default path which will be opened in the Files view. Unlike the index paths, shell variables cannot be used here.

Type: null or string

Default: null

Example: "/home/username/Music"

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.defaultView
The default view which will be opened when Elisa is started.

Type: null or one of “nowPlaying”, “recentlyPlayed”, “frequentlyPlayed”, “allAlbums”, “allArtists”, “allTracks”, “allGenres”, “files”, “radios”

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.embeddedView
Select the sidebar-embedded view for Elisa. The selected view will be omitted from the sidebar, and its contents will instead be individually displayed after the main view buttons.

Type: null or one of “albums”, “artists”, “genres”

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.showNowPlayingBackground
Set to true in order to use a blurred version of the album artwork as the background for the ‘Now Playing’ section in Elisa. Set to false in order to use a solid colour inherited from the Plasma theme.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.appearance.showProgressOnTaskBar
Whether to present the current track progress in the task manager widgets in panels.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.indexer.paths
Stateful, persistent paths to be indexed by the Elisa Indexer. The Indexer will recursively search for valid music files along the given paths. Shell variables, such as $HOME, may be used freely.

Type: null or (list of string)

Default: null

Example:

''
  [
    "$HOME/Music"
    "/ExternalDisk/more-music"
  ]
''
Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.indexer.ratingsStyle
The Elisa music database can attach user-defined ratings to each track. This option defines if the rating is a 0-5 stars rating, or a binary Favourite/Not Favourite rating.

Type: null or one of “stars”, “favourites”

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.indexer.scanAtStartup
Whether to automatically scan the configured index paths for new tracks when Elisa is started.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.player.minimiseToSystemTray
Set to true in order to make Elisa continue playing in the System Tray after being closed. Set to false in order to make Elisa quit after being closed.

By default, the system tray icon is the symbolic variant of the Elisa icon.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.player.playAtStartup
Whether to automatically play the previous track when Elisa is started.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.elisa.player.useAbsolutePlaylistPaths
Set to true in order to make Elisa write .m3u8 playlist files using the absolute paths to each track. Setting to false will make Elisa intelligently pick between relative or absolute paths.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/elisa.nix>
programs.ghostwriter.enable
Whether to enable configuration management for Ghostwriter. .

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.package
The ghostwriter package to use. Use pkgs.libsForQt5.ghostwriter for Plasma 5 and pkgs.kdePackages.ghostwriter for Plasma 6. Use null if home-manager should not install Ghostwriter.

Type: null or package

Default: pkgs.kdePackages.ghostwriter

Example: pkgs.kdePackages.ghostwriter

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.styling.blockquoteStyle
The style of blockquotes.

Type: null or one of “simple”, “italic”

Default: null

Example: "simple"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.styling.editorWidth
The width of the editor.

Type: null or one of “narrow”, “medium”, “wide”, “full”

Default: null

Example: "medium"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.styling.emphasisStyle
The style of emphasis.

Type: null or one of “italic”, “underline”

Default: null

Example: "bold"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.styling.focusMode
The focus mode to use.

Type: null or one of “sentence”, “currentLine”, “threeLines”, “paragraph”, “typewriter”

Default: null

Example: "sentence"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.styling.useLargeHeadings
Whether to use large headings.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.tabulation.insertSpacesForTabs
Whether to insert spaces for tabs.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.tabulation.tabWidth
The width of a tab.

Type: null or (positive integer, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.typing.automaticallyMatchCharacters.enable
Whether to automatically match characters.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.typing.automaticallyMatchCharacters.characters
The characters to automatically match.

Type: null or string

Default: null

Example: "\\\"'([{*_`<"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.editor.typing.bulletPointCycling
Whether to cycle through bullet points.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font
The font to use for Ghostwriter.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 12;
}
Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more information.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more information.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.font.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.display.hideMenubarInFullscreen
Whether to hide the menubar in fullscreen mode.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.display.interfaceStyle
The interface style to use for Ghostwriter.

Type: null or one of “rounded”, “square”

Default: null

Example: "rounded"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.display.showCurrentTimeInFullscreen
Whether to show the current time in fullscreen mode.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.display.showUnbreakableSpace
Whether to show unbreakable space.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.fileSaving.autoSave
Whether to enable auto-save.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.fileSaving.backupFileOnSave
Whether to backup the file on save.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.fileSaving.backupLocation
The location to store backups of the Ghostwriter configuration.

Type: null or absolute path

Default: null

Example: "/home/user/.local/share/ghostwriter/backups"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.session.openLastFileOnStartup
Whether to open the last file on startup.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.general.session.rememberRecentFiles
Whether to remember recent files.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.locale
The locale to use for Ghostwriter.

Type: null or string

Default: null

Example: "en_US"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont
The code font to use for the preview.

Type: null or (submodule)

Default: null

Example:

{
  family = "Hack";
  pointSize = 12;
}
Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more information.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more information.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.codeFont.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.commandLineOptions
Additional command line options to pass to the preview command.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.markdownVariant
The markdown variant to use for the preview.

Type: null or string

Default: null

Example: "cmark-gfm"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.openByDefault
Whether to open the preview by default.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont
The text font to use for the preview.

Type: null or (submodule)

Default: null

Example:

{
  family = "Inter";
  pointSize = 12;
}
Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more information.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more information.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.preview.textFont.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.autoDetectLanguage
Whether to auto-detect the language.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.checkerEnabledByDefault
Whether the checker is enabled by default.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.ignoreUppercase
Whether to ignore uppercase words.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.ignoredWords
Words to ignore in the spell checker.

Type: null or (list of string)

Default: null

Example:

[
  "Amarok"
  "KHTML"
  "NixOS"
]
Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.liveSpellCheck
Whether to enable live spell checking.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.spelling.skipRunTogether
Whether to skip run-together words.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.theme.customThemes
Custom themes to be added to the installation. The attribute key is mapped to their name. Choose them from programs.ghostwriter.theme.name.

Type: attribute set of absolute path

Default: { }

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.theme.name
The name of the theme to use.

Type: null or string

Default: null

Example: "Ghostwriter"

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.ghostwriter.window.sidebarOpen
Whether the sidebar is open by default.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/apps/ghostwriter.nix>
programs.kate.enable
Whether to enable configuration management for Kate, the KDE Advanced Text Editor. .

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.package
The kate package to use. Which Kate package to be installed by home-manager. Use pkgs.libsForQt5.kate for Plasma 5 and pkgs.kdePackages.kate for Plasma 6. Use null if home-manager should not install Kate.

Type: null or package

Default: pkgs.kdePackages.kate

Example: pkgs.libsForQt5.kate

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.dap.customServers
Add more DAP server settings here. Check out the format on the Kate Documentation. Note that these are only the settings; the appropriate packages have to be installed separately.

Type: null or (attribute set)

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.brackets.automaticallyAddClosing
When enabled, a closing bracket is automatically inserted upon typing the opening.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.brackets.characters
This options determines which characters kate will treat as brackets.

Type: string

Default: "<>(){}[]'\"`"

Example: "<>(){}[]'\"`*_~"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.brackets.flashMatching
When this option is enabled, then a bracket will quickly flash whenever the cursor moves adjacent to the corresponding bracket.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.brackets.highlightMatching
When enabled, and the cursor is adjacent to a closing bracket, and the corresponding closing bracket is outside of the currently visible area, then the line of the opening bracket and the line directly after will be shown in a small, floating window at the top of the text area.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.brackets.highlightRangeBetween
This option enables automatch highlighting of the lines between an opening and a closing bracket when the cursor is adjacent to either.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font
The font settings for the editor.

Type: submodule

Default:

{
  family = "Hack";
  pointSize = 10;
}
Example:

{
  family = "Fira Code";
  pointSize = 11;
}
Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.font.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.autodetect
Whether Kate should try to detect indentation for each given file and not impose default indentation settings.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.backspaceDecreaseIndent
Whether the backspace key in the indentation should decrease indentation by a full level always.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.keepExtraSpaces
Whether additional spaces that do not match the indent should be kept when adding/removing indentation level. If these are kept (option to true) then indenting 1 space further (with a default of 4 spaces) will be set to 5 spaces.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.replaceWithSpaces
Whether all indentation should be automatically converted to spaces.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.showLines
Whether to show the vertical lines that mark each indentation level.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.tabFromEverywhere
Whether the tabulator key increases intendation independent from the current cursor position.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.undoByShiftTab
Whether to unindent the current line by one level with the shortcut Shift+Tab.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.indent.width
The width of each indent level (in number of spaces).

Type: signed integer

Default: 4

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.inputMode
The input mode for the editor.

Type: one of “normal”, “vi”

Default: "normal"

Example: "vi"

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.tabWidth
The width of a single tab ( ) sign (in number of spaces).

Type: signed integer

Default: 4

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.theme.name
The name of the theme in use. May be a system theme. If a theme file was submitted this setting will be set automatically.

Type: string

Default: ""

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.editor.theme.src
The path of a theme file for the KDE editor (not the window color scheme). Obtain a custom one by using the GUI settings in Kate. If you want to use a system-wide editor color scheme set this path to null. If you set the metadata.name entry in the file to a value that matches the name of a system-wide color scheme undesired behaviour may occur. The activation will fail if a theme with the filename <name of your theme>.theme already exists.

Type: null or absolute path

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.lsp.customServers
Add more LSP server settings here. Check out the format on the Kate Documentation. Note that these are only the settings; the appropriate packages have to be installed separately.

Type: null or (attribute set)

Default: null

Declared by:

<plasma-manager/modules/apps/kate>
programs.kate.ui.colorScheme
The colour scheme of the UI. Leave this setting at null in order to not override the systems default scheme for for this application.

Type: null or string

Default: null

Example: "Krita dark orange"

Declared by:

<plasma-manager/modules/apps/kate>
programs.konsole.enable
Whether to enable configuration management for Konsole, the KDE Terminal. .

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.customColorSchemes
Custom color schemes to be added to the installation. The attribute key maps to their name. Choose them in any profile with profiles.<profile>.colorScheme = <name>;

Type: attribute set of absolute path

Default: { }

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.defaultProfile
The name of the Konsole profile file to use by default. To see what options you have, take a look at $HOME/.local/share/konsole

Type: null or string

Default: null

Example: "Catppuccin"

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.extraConfig
Extra config to add to the konsolerc.

Type: attribute set of attribute set of (null or boolean or floating point number or signed integer or string)

Default: { }

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles
Plasma profiles to generate.

Type: null or (attribute set of (submodule))

Default: { }

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.colorScheme
Color scheme the profile will use. You can check the files you can use in $HOME/.local/share/konsole or /run/current-system/sw/share/konsole. You might also add a custom color scheme using programs.konsole.customColorSchemes.

Type: null or string

Default: null

Example: "Catppuccin-Mocha"

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.command
The command to run on new sessions.

Type: null or string

Default: null

Example: "${pkgs.zsh}/bin/zsh"

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.extraConfig
Extra keys to manually add to the profile.

Type: attribute set of attribute set of (null or boolean or floating point number or signed integer or string)

Default: { }

Example: { }

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.font.name
Name of the font the profile should use.

Type: string

Default: "Hack"

Example: "Hack"

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.font.size
Size of the font. Due to Konsole limitations, only a limited range of sizes is possible.

Type: integer or floating point number between 4 and 128 (both inclusive)

Default: 10

Example: 12

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.profiles.<name>.name
Name of the profile. Defaults to the attribute name.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.konsole.ui.colorScheme
The color scheme of the UI. Leave this setting at null in order to not override the system’s default scheme for for this application.

Type: null or string

Default: null

Example: "Krita dark orange"

Declared by:

<plasma-manager/modules/apps/konsole.nix>
programs.okular.enable
Whether to enable configuration management for okular. .

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.package
The okular package to use. Which okular package to install. Use pkgs.libsForQt5.okular in Plasma5 and pkgs.kdePackages.okular in Plasma6. Use null if home-manager should not install Okular.

Type: null or package

Default: pkgs.kdePackages.okular

Example: pkgs.libsForQt5.okular

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.enable
Whether to change the colors of the documents.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.blackWhiteContrast
New contrast strength. Used for the BlackWhite mode.

Type: null or integer between 2 and 6 (both inclusive)

Default: null

Example: 4

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.blackWhiteThreshold
A threshold for deciding between black and white. Higher values lead to brighter grays. Used for the BlackWhite mode.

Type: null or integer or floating point number between 2 and 253 (both inclusive)

Default: null

Example: 127

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.mode
Mode used to change the colors.

Type: null or one of “Inverted”, “Paper”, “Recolor”, “BlackWhite”, “InvertLightness”, “InvertLumaSymmetric”, “InvertLuma”, “HueShiftPositive”, “HueShiftNegative”

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.paperColor
Paper color in RGB. Used for the Paper mode.

Type: null or string

Default: null

Example: "255,255,255"

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.recolorBackground
New background color in RGB. Used for the Recolor mode.

Type: null or string

Default: null

Example: "0,0,0"

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.changeColors.recolorForeground
New foreground color in RGB. Used for the Recolor mode.

Type: null or string

Default: null

Example: "255,255,255"

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.accessibility.highlightLinks
Whether to draw borders around links.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.mouseMode
Changes what the mouse does. See the Okular Documentation for the full description.

Browse: Click-and-drag with left mouse button.

Zoom: Zoom in with left mouse button. Reset zoom with right mouse button.

RectSelect: Draw area selection with left mouse button. Display options with right mouse button.

TextSelect: Select text with left mouse button. Display options with right mouse button.

TableSelect: Similar to text selection but allows for transforming the document into a table.

Magnifier: Activates the magnifier with left mouse button.

Type: null or one of “Browse”, “Zoom”, “RectSelect”, “TextSelect”, “TableSelect”, “Magnifier”, “TrimSelect”

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.obeyDrm
Whether Okular should obey DRM (Digital Rights Management) restrictions. DRM limitations are used to make it impossible to perform certain actions with PDF documents, such as copying content to the clipboard. Note that in some configurations of Okular, this option is not available.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.openFileInTabs
Whether to open files in tabs.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.showScrollbars
Whether to show scrollbars in the document viewer.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.smoothScrolling
Whether to use smooth scrolling.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.viewContinuous
Whether to open in continous mode by default.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.viewMode
The view mode for the pages.

Type: null or one of “Single”, “Facing”, “FacingFirstCentered”, “Summary”

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.general.zoomMode
Specifies the default zoom mode for file which were never opened before. For those files which were opened before the previous zoom mode is applied.

Type: null or one of “100%”, “fitWidth”, “fitPage”, “autoFit”

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.performance.enableTransparencyEffects
Whether to enable transparancy effects. This may increase CPU usage.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.okular.performance.memoryUsage
Memory usage profile for Okular. This may impact the speed performance of Okular, as it determines how many computation results are kept in memory.

Type: null or one of “Low”, “Normal”, “Aggressive”, “Greedy”

Default: null

Declared by:

<plasma-manager/modules/apps/okular.nix>
programs.plasma.enable
Whether to enable declarative configuration options for the KDE Plasma Desktop. .

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules>
programs.plasma.configFile
An attribute set where the keys are file names (relative to $XDG_CONFIG_HOME) and the values are attribute sets that represent configuration groups and settings inside those groups.

Type: attribute set of attribute set of attribute set of ((submodule) or (null or boolean or floating point number or signed integer or string) convertible to it)

Default: { }

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.configFile.<name>.<name>.<name>.escapeValue
Whether to escape the value according to kde’s escape-format. See: https://invent.kde.org/frameworks/kconfig/-/blob/v6.7.0/src/core/kconfigini.cpp?ref_type=tags#L880-945 for info about this format.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.configFile.<name>.<name>.<name>.immutable
Whether to make the key immutable. This corresponds to adding [$i] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.configFile.<name>.<name>.<name>.persistent
When overrideConfig is enabled and the key is persistent, plasma-manager will leave it unchanged after activation.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.configFile.<name>.<name>.<name>.shellExpand
Whether to mark the key for shell expansion. This corresponds to adding [$e] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.configFile.<name>.<name>.<name>.value
The value for some key.

Type: null or boolean or floating point number or signed integer or string

Default: null

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile
An attribute set where the keys are file names (relative to $XDG_DATA_HOME) and the values are attribute sets that represent configuration groups and settings inside those groups.

Type: attribute set of attribute set of attribute set of ((submodule) or (null or boolean or floating point number or signed integer or string) convertible to it)

Default: { }

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile.<name>.<name>.<name>.escapeValue
Whether to escape the value according to kde’s escape-format. See: https://invent.kde.org/frameworks/kconfig/-/blob/v6.7.0/src/core/kconfigini.cpp?ref_type=tags#L880-945 for info about this format.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile.<name>.<name>.<name>.immutable
Whether to make the key immutable. This corresponds to adding [$i] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile.<name>.<name>.<name>.persistent
When overrideConfig is enabled and the key is persistent, plasma-manager will leave it unchanged after activation.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile.<name>.<name>.<name>.shellExpand
Whether to mark the key for shell expansion. This corresponds to adding [$e] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.dataFile.<name>.<name>.<name>.value
The value for some key.

Type: null or boolean or floating point number or signed integer or string

Default: null

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.desktop.icons.alignment
Whether to align the icons on the left (the default) or right side of the screen.

Type: null or one of “left”, “right”

Default: null

Example: "right"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.arrangement
The direction in which desktop icons are to be arranged.

Type: null or one of “leftToRight”, “topToBottom”

Default: null

Example: "topToBottom"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.folderPreviewPopups
Enables the arrow button when hovering over a folder on the desktop which shows a preview popup of the folder’s contents.

Enabled by default.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.lockInPlace
Locks the position of all desktop icons to the order and placement defined by arrangement, alignment and the sorting options, so they cannot be manually moved.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.previewPlugins
Configures the preview plugins used to preview desktop files and folders.

Type: null or (list of string)

Default: null

Example:

[
  "audiothumbnail"
  "fontthumbnail"
]
Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.size
The desktop icon size, which is normally configured via a slider with seven possible values ranging from small (0) to large (6). The fourth position (3) is the default.

Type: null or integer between 0 and 6 (both inclusive)

Default: null

Example: 2

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.sorting.descending
Reverses the sorting order if enabled. Sorting is ascending by default.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.sorting.foldersFirst
Folders are sorted separately from files by default. This means folders appear first, sorted, for example, ascending by name, followed by files, also sorted ascending by name. If this option is disabled, all items are sorted regardless of type.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.icons.sorting.mode
Specifies the sort mode for the desktop icons. By default, they are sorted by name.

Type: null or one of “date”, “manual”, “name”, “size”, “type”

Default: null

Example: "type"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.mouseActions.leftClick
Action for a left mouse click on the desktop.

Type: null or one of “applicationLauncher”, “contextMenu”, “paste”, “switchActivity”, “switchVirtualDesktop”, “switchWindow”

Default: null

Example: "appLauncher"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.mouseActions.middleClick
Action for a middle mouse click on the desktop.

Type: null or one of “applicationLauncher”, “contextMenu”, “paste”, “switchActivity”, “switchVirtualDesktop”, “switchWindow”

Default: null

Example: "switchWindow"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.mouseActions.rightClick
Action for a right mouse click on the desktop.

Type: null or one of “applicationLauncher”, “contextMenu”, “paste”, “switchActivity”, “switchVirtualDesktop”, “switchWindow”

Default: null

Example: "contextMenu"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.mouseActions.verticalScroll
Action for scrolling (vertically) while hovering over the desktop.

Type: null or one of “applicationLauncher”, “contextMenu”, “paste”, “switchActivity”, “switchVirtualDesktop”, “switchWindow”

Default: null

Example: "switchVirtualDesktop"

Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.desktop.widgets
A list of widgets to be added to the desktop.

Type: null or (list of (attribute-tagged union or (submodule)))

Default: null

Example:

[
  {
    config = {
      Appearance = {
        showDate = false;
      };
    };
    name = "org.kde.plasma.digitalclock";
    position = {
      horizontal = 51;
      vertical = 100;
    };
    size = {
      height = 250;
      width = 250;
    };
  }
  {
    plasmusicToolbar = {
      background = "transparentShadow";
      position = {
        horizontal = 51;
        vertical = 300;
      };
      size = {
        height = 400;
        width = 250;
      };
    };
  }
]
Declared by:

<plasma-manager/modules/desktop.nix>
programs.plasma.file
An attribute set where the keys are file names (relative to $HOME) and the values are attribute sets that represent configuration groups and settings inside those groups.

Type: attribute set of attribute set of attribute set of ((submodule) or (null or boolean or floating point number or signed integer or string) convertible to it)

Default: { }

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.file.<name>.<name>.<name>.escapeValue
Whether to escape the value according to kde’s escape-format. See: https://invent.kde.org/frameworks/kconfig/-/blob/v6.7.0/src/core/kconfigini.cpp?ref_type=tags#L880-945 for info about this format.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.file.<name>.<name>.<name>.immutable
Whether to make the key immutable. This corresponds to adding [$i] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.file.<name>.<name>.<name>.persistent
When overrideConfig is enabled and the key is persistent, plasma-manager will leave it unchanged after activation.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.file.<name>.<name>.<name>.shellExpand
Whether to mark the key for shell expansion. This corresponds to adding [$e] to the end of the key.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.file.<name>.<name>.<name>.value
The value for some key.

Type: null or boolean or floating point number or signed integer or string

Default: null

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.fonts.fixedWidth
The fixed width or monospace font for the Plasma desktop.

Type: null or (submodule)

Default: null

Example:

{
  family = "Iosevka";
  pointSize = 11;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.fixedWidth.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general
The main font for the Plasma desktop.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 11;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.general.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu
The font used for menus.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 10;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.menu.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small
The font used for very small text.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 8;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.small.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar
The font used for toolbars.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 10;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.toolbar.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle
The font used for window titles.

Type: null or (submodule)

Default: null

Example:

{
  family = "Noto Sans";
  pointSize = 10;
}

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.capitalization
The capitalization settings for this font.

See https://doc.qt.io/qt-6/qfont.html#Capitalization-enum for more.

Type: one of “allLowercase”, “allUppercase”, “capitalize”, “mixedCase”, “smallCaps”

Default: "mixedCase"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.family
The font family of this font.

Type: string

Example: "Noto Sans"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.fixedPitch
Whether the font has a fixed pitch.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.letterSpacing
The amount of letter spacing for this font.

Could be a percentage or an absolute spacing change (positive increases spacing, negative decreases spacing), based on the selected letterSpacingType.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.letterSpacingType
Whether to use percentage or absolute spacing for this font.

See https://doc.qt.io/qt-6/qfont.html#SpacingType-enum for more.

Type: one of “absolute”, “percentage”

Default: "percentage"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.pixelSize
The pixel size of this font.

Mutually exclusive with point size.

Type: null or 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.pointSize
The point size of this font.

Could be a decimal, but usually an integer. Mutually exclusive with pixel size.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.stretch
The stretch factor for this font, as an integral percentage (i.e. 150 means a 150% stretch), or as a pre-defined stretch factor string.

Type: integer between 1 and 4000 (both inclusive) or one of “anyStretch”, “condensed”, “expanded”, “extraCondensed”, “extraExpanded”, “semiCondensed”, “semiExpanded”, “ultraCondensed”, “ultraExpanded”, “unstretched”

Default: "anyStretch"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.strikeOut
Whether the font is struck out.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.style
The style of the font.

Type: one of “italic”, “normal”, “oblique”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleHint
The style hint of this font.

See https://doc.qt.io/qt-6/qfont.html#StyleHint-enum for more.

Type: one of “anyStyle”, “courier”, “cursive”, “decorative”, “fantasy”, “helvetica”, “monospace”, “oldEnglish”, “sansSerif”, “serif”, “system”, “times”, “typewriter”

Default: "anyStyle"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleName
The style name of this font, overriding the style and weight parameters when set. Used for special fonts that have styles beyond traditional settings.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy
The strategy for matching similar fonts to this font.

See https://doc.qt.io/qt-6/qfont.html#StyleStrategy-enum for more.

Type: submodule

Default: { }

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.antialiasing
Whether antialiasing is preferred for this font.

default corresponds to not setting any enum flag, and prefer and disable correspond to PreferAntialias and NoAntialias enum flags respectively.

Type: one of “default”, “disable”, “prefer”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.matchingPrefer
Whether the font matching process prefers exact matches, or best quality matches.

default corresponds to not setting any enum flag, and exact and quality correspond to PreferMatch and PreferQuality enum flags respectively.

Type: one of “default”, “exact”, “quality”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.noFontMerging
If set to true, this font will not try to find a substitute font when encountering missing glyphs.

Corresponds to the NoFontMerging enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.noSubpixelAntialias
If set to true, this font will try to avoid subpixel antialiasing.

Corresponds to the NoSubpixelAntialias enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.prefer
Which type of font is preferred by the font when finding an appropriate default family.

default, bitmap, device, outline, forceOutline correspond to the PreferDefault, PreferBitmap, PreferDevice, PreferOutline, ForceOutline enum flags respectively.

Type: one of “bitmap”, “default”, “device”, “forceOutline”, “outline”

Default: "default"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.styleStrategy.preferNoShaping
If set to true, this font will not try to apply shaping rules that may be required for some scripts (e.g. Indic scripts), increasing performance if these rules are not required.

Corresponds to the PreferNoShaping enum flag.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.underline
Whether the font is underlined.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.weight
The weight of the font, either as a number between 1 to 1000 or as a pre-defined weight string.

See https://doc.qt.io/qt-6/qfont.html#Weight-enum for more.

Type: integer between 1 and 1000 (both inclusive) or one of “black”, “bold”, “demiBold”, “extraBold”, “extraLight”, “light”, “medium”, “normal”, “thin”

Default: "normal"

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.fonts.windowTitle.wordSpacing
The amount of word spacing for this font, in pixels.

Positive values increase spacing while negative ones decrease spacing.

Type: signed integer or floating point number

Default: 0

Declared by:

<plasma-manager/modules/fonts.nix>
programs.plasma.hotkeys.commands
Commands triggered by a keyboard shortcut.

Type: attribute set of (submodule)

Default: { }

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.command
The command to execute.

Type: string

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.comment
Optional comment to display in the System Settings app.

Type: string

Default: "‹name›"

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.key
The key combination that triggers the action.

Type: string

Default: ""

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.keys
The key combinations that trigger the action.

Type: list of string

Default: [ ]

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.logs.enabled
Connect the command’s stdin and stdout to the systemd journal with systemd-cat.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.logs.extraArgs
Additional arguments provided to systemd-cat.

Type: string

Default: ""

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.logs.identifier
Identifier passed down to systemd-cat.

Type: string

Default: "plasma-manager-commands-‹name›"

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.hotkeys.commands.<name>.name
Command hotkey name.

Type: string

Default: "‹name›"

Declared by:

<plasma-manager/modules/hotkeys.nix>
programs.plasma.immutableByDefault
Whether to make keys written by plasma-manager immutable by default.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.input.keyboard.layouts
Keyboard layouts to use.

Type: null or (list of (submodule))

Default: null

Example:

[
  {
    layout = "us";
  }
  {
    layout = "ca";
    variant = "eng";
  }
  {
    displayName = "usi";
    layout = "us";
    variant = "intl";
  }
]
Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.layouts.*.displayName
Keyboard layout display name.

Type: null or string

Default: null

Example: "us"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.layouts.*.layout
Keyboard layout.

Type: string

Example: "us"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.layouts.*.variant
Keyboard layout variant. Examples: “mac”, “dvorak”, “workman-intl”, and “colemak_dh_wide_iso”

Type: null or string

Default: null

Example: "eng"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.model
Keyboard model.

Type: null or string

Default: null

Example: "pc104"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.numlockOnStartup
Numpad settings at startup.

Type: null or one of “on”, “off”, “unchanged”

Default: null

Example: "on"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.options
Keyboard options.

Type: null or (list of string)

Default: null

Example:

[
  "altwin:meta_alt"
  "caps:shift"
  "custom:types"
]
Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.repeatDelay
Configure how many milliseconds a key must be held down for before the input starts repeating.

Type: null or integer between 100 and 5000 (both inclusive)

Default: null

Example: 200

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.repeatRate
Configure how quickly the inputs should be repeated when holding down a key.

Type: null or integer or floating point number between 0.2 and 100.0 (both inclusive)

Default: null

Example: 50.0

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.keyboard.switchingPolicy
Switching policy for keyboard layouts.

Type: null or one of “global”, “desktop”, “winClass”, “window”

Default: null

Example: "global"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice
Configure the different mice.

Type: list of (submodule)

Default: [ ]

Example:

[
  {
    acceleration = 0.5;
    accelerationProfile = "none";
    enable = true;
    leftHanded = false;
    middleButtonEmulation = false;
    name = "Logitech G403 HERO Gaming Mouse";
    naturalScroll = false;
    productId = "c08f";
    scrollSpeed = 1;
    vendorId = "046d";
  }
]
Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.enable
Enables or disables the mouse.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.acceleration
Set the mouse acceleration.

Type: null or integer or floating point number between -1 and 1 (both inclusive)

Default: null

Example: 0.5

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.accelerationProfile
Set the mouse acceleration profile.

Type: null or one of “default”, “none”

Default: null

Example: "none"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.leftHanded
Whether to swap the left and right buttons.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.middleButtonEmulation
Whether to enable middle mouse click emulation by pressing the left and right buttons at the same time. Activating this increases the click latency by 50ms.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.name
The name of the mouse.

This can be found by looking at the Name attribute in the section in the /proc/bus/input/devices path belonging to the mouse.

Type: string

Default: null

Example: "Logitech G403 HERO Gaming Mouse"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.naturalScroll
Whether to enable natural scrolling for the mouse.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.productId
The product ID of the mouse.

This can be found by looking at the Product attribute in the section in the /proc/bus/input/devices path belonging to the mouse.

Type: string

Default: null

Example: "c077"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.scrollSpeed
Configure how fast the scroll wheel moves.

Type: null or integer or floating point number between 0.1 and 20 (both inclusive)

Default: null

Example: 1

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.mice.*.vendorId
The vendor ID of the mouse.

This can be found by looking at the Vendor attribute in the section in the /proc/bus/input/devices path belonging to the mouse.

Type: string

Default: null

Example: "046d"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads
Configure the different touchpads.

Type: list of (submodule)

Default: [ ]

Example:

[
  {
    disableWhileTyping = true;
    enable = true;
    leftHanded = true;
    middleButtonEmulation = true;
    name = "PNP0C50:00 0911:5288 Touchpad";
    naturalScroll = true;
    pointerSpeed = 0;
    productId = "21128";
    tapToClick = true;
    vendorId = "2321";
  }
]
Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.enable
Whether to enable the touchpad.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.accelerationProfile
Set the touchpad acceleration profile.

Type: null or one of “default”, “none”

Default: null

Example: "none"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.disableWhileTyping
Whether to disable the touchpad while typing.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.leftHanded
Whether to swap the left and right buttons.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.middleButtonEmulation
Whether to enable middle mouse click emulation by pressing the left and right buttons at the same time. Activating this increases the click latency by 50ms.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.name
The name of the touchpad.

This can be found by looking at the Name attribute in the section in the /proc/bus/input/devices path belonging to the touchpad.

Type: string

Default: null

Example: "PNP0C50:00 0911:5288 Touchpad"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.naturalScroll
Whether to enable natural scrolling for the touchpad.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.pointerSpeed
How fast the pointer moves.

Type: null or integer or floating point number between -1 and 1 (both inclusive)

Default: null

Example: "0"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.productId
The product ID of the touchpad.

This can be found by looking at the Product attribute in the section in the /proc/bus/input/devices path belonging to the touchpad.

Type: string

Default: null

Example: "5288"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.rightClickMethod
Configure how right-clicking is performed on the touchpad.

Type: null or one of “bottomRight”, “twoFingers”

Default: null

Example: "twoFingers"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.scrollMethod
Configure how scrolling is performed on the touchpad.

Type: null or one of “touchPadEdges”, “twoFingers”

Default: null

Example: "touchPadEdges"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.scrollSpeed
Configure the scrolling speed of the touchpad. Lower is slower. If unset, KDE Plasma will default to 0.3.

Type: null or integer or floating point number between 0.1 and 20 (both inclusive)

Default: null

Example: 0.1

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.tapAndDrag
Whether to enable tap-and-drag for the touchpad.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.tapDragLock
Whether to enable the tap-and-drag lock for the touchpad.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.tapToClick
Whether to enable tap-to-click for the touchpad.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.twoFingerTap
Configure what a two-finger tap maps to on the touchpad.

Type: null or one of “rightClick”, “middleClick”

Default: null

Example: "twoFingers"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.input.touchpads.*.vendorId
The vendor ID of the touchpad.

This can be found by looking at the Vendor attribute in the section in the /proc/bus/input/devices path belonging to the touchpad.

Type: string

Default: null

Example: "0911"

Declared by:

<plasma-manager/modules/input.nix>
programs.plasma.krunner.activateWhenTypingOnDesktop
Whether to activate KRunner when typing on the desktop.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/krunner.nix>
programs.plasma.krunner.historyBehavior
Set the behavior of KRunner’s history.

Type: null or one of “disabled”, “enableSuggestions”, “enableAutoComplete”

Default: null

Example: "disabled"

Declared by:

<plasma-manager/modules/krunner.nix>
programs.plasma.krunner.position
Set KRunner’s position on the screen.

Type: null or one of “top”, “center”

Default: null

Example: "center"

Declared by:

<plasma-manager/modules/krunner.nix>
programs.plasma.krunner.shortcuts.launch
Set the shortcut to launch KRunner.

Type: null or string or list of string

Default: null

Example: "Meta"

Declared by:

<plasma-manager/modules/krunner.nix>
programs.plasma.krunner.shortcuts.runCommandOnClipboard
Set the shortcut to run the command on the clipboard contents.

Type: null or string or list of string

Default: null

Example: "Meta+Shift"

Declared by:

<plasma-manager/modules/krunner.nix>
programs.plasma.kscreenlocker.appearance.alwaysShowClock
Whether to always show the clock on the lockscreen, even if the unlock dialog is not shown.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.showMediaControls
Whether to show media controls on the lockscreen.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaper
The wallpaper for the lockscreen. Can be either the path to an image file or a KPackage.

Type: null or absolute path

Default: null

Example: "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Kay/contents/images/1080x1920.png"

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperPictureOfTheDay
Which plugin to fetch the Picture of the Day from.

Type: null or (submodule)

Default: null

Example:

{
  provider = "apod";
}
Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperPictureOfTheDay.provider
The provider for the Picture of the Day plugin.

Type: null or one of “apod”, “bing”, “flickr”, “natgeo”, “noaa”, “wcpotd”, “epod”, “simonstalenhag”

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperPictureOfTheDay.updateOverMeteredConnection
Whether to update the wallpaper on a metered connection.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperPlainColor
Set the wallpaper using a plain color. Color is a comma-seperated R,G,B,A string. The alpha is optional (default is 256).

Type: null or string

Default: null

Example: "0,64,174,256"

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperSlideShow
Allows you to set the wallpaper using the slideshow plugin. Needs the path to at least one directory with wallpaper images.

Type: null or (submodule)

Default: null

Example: { path = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/"; }

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperSlideShow.interval
The length between wallpaper switches.

Type: signed integer

Default: 300

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.appearance.wallpaperSlideShow.path
The path(s) where the wallpapers are located.

Type: absolute path or list of absolute path

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.autoLock
Whether the screen will be locked after the specified time.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.lockOnResume
Whether to lock the screen when the system resumes from sleep.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.lockOnStartup
Whether to lock the screen on startup.

Note: This option is not provided in the System Settings app.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.passwordRequired
Whether the user password is required to unlock the screen.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.passwordRequiredDelay
The time it takes in seconds for the password to be required after the screen is locked.

Type: null or (unsigned integer, meaning >=0)

Default: null

Example: 5

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kscreenlocker.timeout
Sets the timeout in minutes after which the screen will be locked.

Type: null or (unsigned integer, meaning >=0)

Default: null

Example: 5

Declared by:

<plasma-manager/modules/kscreenlocker.nix>
programs.plasma.kwin.borderlessMaximizedWindows
Whether to remove the border of maximized windows.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.cornerBarrier
When enabled, prevents the cursor from crossing at screen-corners.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.edgeBarrier
Additional distance the cursor needs to travel to cross screen edges. To disable edge barriers, set this to 0.

Type: null or integer between 0 and 1000 (both inclusive)

Default: null

Example: 50

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.blur.enable
Blurs the background behind semi-transparent windows.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.blur.noiseStrength
Adds noise to the blur effect.

Type: null or integer between 0 and 14 (both inclusive)

Default: null

Example: 8

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.blur.strength
Controls the intensity of the blur.

Type: null or integer between 1 and 15 (both inclusive)

Default: null

Example: 5

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.cube.enable
Arrange desktops in a virtual cube.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.desktopSwitching.animation
The animation used when switching through virtual desktops.

Type: null or one of “fade”, “slide”, “off”

Default: null

Example: "fade"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.desktopSwitching.navigationWrapping
Whether to wrap around when switching through virtual desktops.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.dimAdminMode.enable
Darken the entire screen, except for the PolKit window, when requesting root privileges.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.dimInactive.enable
Darken inactive windows.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.fallApart.enable
Whether to make closed windows break into pieces.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.fps.enable
Display KWin’s FPS performance graph in the corner of the screen.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.hideCursor.enable
Enable the hide cursor effect.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.hideCursor.hideOnInactivity
Hide cursor after inactivity in seconds.

Type: null or (unsigned integer, meaning >=0)

Default: null

Example: 0

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.hideCursor.hideOnTyping
Hide cursor effect while typing.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.invert.enable
Enable the invert effect toggle.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.magnifier.enable
Enable the magnifier effect.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.magnifier.height
Height of the magnifier section in pixels.

Type: null or (positive integer, meaning >0)

Default: null

Example: 200

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.magnifier.width
Width of the magnifier section in pixels.

Type: null or (positive integer, meaning >0)

Default: null

Example: 200

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.minimization.animation
The effect to be displayed when windows are minimized.

Type: null or one of “squash”, “magiclamp”, “off”

Default: null

Example: "magiclamp"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.minimization.duration
The duration of the minimization effect in milliseconds. Only available when the minimization effect is magiclamp.

Type: null or (positive integer, meaning >0)

Default: null

Example: 50

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.shakeCursor.enable
Enable the shake cursor effect.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.slideBack.enable
Slide back windows when another window is raised.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.snapHelper.enable
Helps locate the center of the screen when moving a window.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.translucency.enable
Make windows translucent under certain conditions.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.windowOpenClose.animation
The animation used when opening/closing windows.

Type: null or one of “fade”, “glide”, “scale”, “off”

Default: null

Example: "glide"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.wobblyWindows.enable
Deform windows while they are moving.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.enable
Enable the zoom effect.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.focusTracking.enable
Enable focus tracking.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.mousePointer
Set the mouse pointer style.

Type: null or one of “scale”, “keep”, “hide”

Default: null

Example: "scale"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.mouseTracking
Set the mouse tracking style.

Type: null or one of “proportional”, “centered”, “push”, “disabled”

Default: null

Example: "proportional"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.pixelGridZoom
Set the zoom level of the pixel grid.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Example: 15.0

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.scrollGestureModKeys
Set scroll gesture modifier keys.

Type: null or (list of string) or string

Default: null

Example: "Meta+Ctrl"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.textCursorTracking.enable
Enable text cursor tracking.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.effects.zoom.zoomFactor
Set the zoom factor.

Type: null or (positive integer or floating point number, meaning >0)

Default: null

Example: 1.2

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.enable
Enable the night light effect.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.location.latitude
The latitude of your location.

Type: null or string

Default: null

Example: "39.160305343511446"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.location.longitude
The longitude of your location.

Type: null or string

Default: null

Example: "-35.86466165413535"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.mode
When to enable the night light effect.

constant enables it unconditonally.

location uses coordinates to figure out the sunset/sunrise times for your location.

times allows you to set the times for enabling and disabling night light.

Type: null or one of “constant”, “location”, “times”

Default: null

Example: "times"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.temperature.day
The temperature of the screen during the day.

Type: null or (positive integer, meaning >0)

Default: null

Example: 4500

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.temperature.night
The temperature of the screen during the night.

Type: null or (positive integer, meaning >0)

Default: null

Example: 4500

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.time.evening
The exact time when the evening light starts.

Type: null or string

Default: null

Example: "19:30"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.time.morning
The exact time when the morning light starts.

Type: null or string

Default: null

Example: "06:30"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.nightLight.transitionTime
The time in minutes it takes to transition from day to night.

Type: null or (positive integer, meaning >0)

Default: null

Example: 30

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.enable
Whether to enable Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.enableDebug
Whether to enable debug mode for Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.borderVisibility
The border visibility setting for Polonium.

Type: null or one of “noBorderAll”, “noBorderTiled”, “borderSelected”, “borderAll”

Default: null

Example: "noBorderAll"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.callbackDelay
The callback delay setting for Polonium.

Type: null or integer between 1 and 200 (both inclusive)

Default: null

Example: 100

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.filter.processes
The processes to filter for Polonium.

Type: null or (list of string)

Default: null

Example:

[
  "firefox"
  "chromium"
]
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.filter.windowTitles
The window titles to filter for Polonium.

Type: null or (list of string)

Default: null

Example:

[
  "Discord"
  "Telegram"
]
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.layout.engine
The layout engine setting for Polonium.

Type: null or one of “binaryTree”, “half”, “threeColumn”, “monocle”, “kwin”

Default: null

Example: "binaryTree"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.layout.insertionPoint
The insertion point setting for Polonium.

Type: null or one of “left”, “right”, “activeWindow”

Default: null

Example: "top"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.layout.rotate
Whether to rotate the layout for Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.maximizeSingleWindow
Whether to maximize a single window for Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.resizeAmount
The resize amount setting for Polonium.

Type: null or integer between 1 and 450 (both inclusive)

Default: null

Example: 100

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.saveOnTileEdit
Whether to save on tile edit for Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.scripts.polonium.settings.tilePopups
Whether to tile popups for Polonium.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.tiling.layout
This option has no description.

Type: null or (submodule)

Default: null

Example:

{
  id = "cf5c25c2-4217-4193-add6-b5971cb543f2";
  tiles = {
    layoutDirection = "horizontal";
    tiles = [
      {
        width = 0.5;
      }
      {
        layoutDirection = "vertical";
        tiles = [
          {
            height = 0.5;
          }
          {
            height = 0.5;
          }
        ];
        width = 0.5;
      }
    ];
  };
}
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.tiling.layout.id
The ID of the layout.

Type: string

Example: "cf5c25c2-4217-4193-add6-b5971cb543f2"

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.tiling.layout.tiles
This option has no description.

Type: attribute set of anything

Example:

{
  layoutDirection = "horizontal";
  tiles = [
    {
      width = 0.5;
    }
    {
      layoutDirection = "vertical";
      tiles = [
        {
          height = 0.5;
        }
        {
          height = 0.5;
        }
      ];
      width = 0.5;
    }
  ];
}
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.tiling.padding
The padding between windows in tiling.

Type: null or integer between 0 and 36 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.titlebarButtons.left
Title bar buttons to be placed on the left.

Type: null or (list of (one of “more-window-actions”, “application-menu”, “on-all-desktops”, “minimize”, “maximize”, “close”, “help”, “shade”, “keep-below-windows”, “keep-above-windows”))

Default: null

Example:

[
  "on-all-desktops"
  "keep-above-windows"
]
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.titlebarButtons.right
Title bar buttons to be placed on the right.

Type: null or (list of (one of “more-window-actions”, “application-menu”, “on-all-desktops”, “minimize”, “maximize”, “close”, “help”, “shade”, “keep-below-windows”, “keep-above-windows”))

Default: null

Example:

[
  "help"
  "minimize"
  "maximize"
  "close"
]
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.virtualDesktops.names
The names of your virtual desktops. When set, the number of virtual desktops is automatically detected and doesn’t need to be specified.

Type: null or (list of string)

Default: null

Example:

[
  "Desktop 1"
  "Desktop 2"
  "Desktop 3"
  "Desktop 4"
]
Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.virtualDesktops.number
The amount of virtual desktops. If the names attribute is set as well, then the number of desktops must be the same as the length of the names list.

Type: null or (positive integer, meaning >0)

Default: null

Example: 8

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.kwin.virtualDesktops.rows
The amount of rows for the virtual desktops.

Type: null or (positive integer, meaning >0)

Default: null

Example: 2

Declared by:

<plasma-manager/modules/kwin.nix>
programs.plasma.overrideConfig
Wether to discard changes made outside plasma-manager. If enabled, all settings not specified explicitly in plasma-manager will be set to the default on next login. This will automatically delete a lot of KDE Plasma configuration files on each generation, so do be careful with this option.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.panels
This option has no description.

Type: list of (submodule)

Default: [ ]

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.alignment
The alignment of the panel.

Type: null or one of “left”, “center”, “right”

Default: "center"

Example: "right"

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.extraSettings
Extra lines to add to the layout.js. See the KDE Documentation for information.

Type: null or string

Default: null

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.floating
Whether to enable floating style…

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.height
The height of the panel.

Type: signed integer

Default: 44

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.hiding
The hiding mode of the panel. Here, windowscover and windowsbelow are Plasma 5-only, while dodgewindows, windowsgobelow and normalpanel are Plasma 6-only.

Type: null or one of “none”, “autohide”, “windowscover”, “windowsbelow”, “dodgewindows”, “normalpanel”, “windowsgobelow”

Default: null

Example: "autohide"

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.lengthMode
The length mode of the panel. Defaults to custom if either minLength or maxLength is set.

Type: null or one of “fit”, “fill”, “custom”

Default: null

Example: "fit"

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.location
The location of the panel.

Type: null or one of “top”, “bottom”, “left”, “right”, “floating”

Default: "bottom"

Example: "left"

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.maxLength
The maximum allowed length/width of the panel.

Type: null or signed integer

Default: null

Example: 1600

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.minLength
The minimum required length/width of the panel.

Type: null or signed integer

Default: null

Example: 1000

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.offset
The offset of the panel from the anchor-point.

Type: null or signed integer

Default: null

Example: 100

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.opacity
The opacity mode of the panel.

Type: null or one of “adaptive”, “opaque”, “translucent”

Default: null

Example: "opaque"

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.screen
The screen the panel should appear on. Can be an int, or a list of ints, starting from 0, representing the ID of the screen the panel should appear on. Alternatively, it can be set to all if the panel should appear on all the screens.

Type: null or unsigned integer, meaning >=0, or (list of (unsigned integer, meaning >=0)) or value “all” (singular enum)

Default: null

Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.panels.*.widgets
The widgets to use in the panel. To get the names, it may be useful to look in the share/plasma/plasmoids subdirectory in the Nix Store path the widget/plasmoid is sourced from. Some packages which include some widgets/plasmoids are, for example, plasma-desktop and plasma-workspace.

Type: list of (string or attribute-tagged union or (submodule))

Default:

[
  "org.kde.plasma.kickoff"
  "org.kde.plasma.pager"
  "org.kde.plasma.icontasks"
  "org.kde.plasma.marginsseparator"
  "org.kde.plasma.systemtray"
  "org.kde.plasma.digitalclock"
  "org.kde.plasma.showdesktop"
]
Example:

[
  "org.kde.plasma.kickoff"
  "org.kde.plasma.icontasks"
  "org.kde.plasma.marginsseparator"
  "org.kde.plasma.digitalclock"
]
Declared by:

<plasma-manager/modules/panels.nix>
programs.plasma.powerdevil.AC.autoSuspend.action
The action, when on AC, to perform after a certain period of inactivity.

Type: null or one of “hibernate”, “nothing”, “shutDown”, “sleep”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.autoSuspend.idleTimeout
The duration (in seconds), when on AC, the computer must be idle for until the auto-suspend action is executed.

Type: null or integer between 60 and 600000 (both inclusive)

Default: null

Example: 600

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.dimDisplay.enable
Whether to enable screen dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.dimDisplay.idleTimeout
The duration (in seconds), when on AC, the computer must be idle until the display starts dimming.

Type: null or integer between 20 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.dimKeyboard.enable
Whether to enable keyboard backlight dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.displayBrightness
The brightness to set the display to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.inhibitLidActionWhenExternalMonitorConnected
If enabled, the lid action will be inhibited when an external monitor is connected.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.keyboardBrightness
The brightness to set the keyboard backlight to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.powerButtonAction
The action, when on AC, to perform when the power button is pressed.

Type: null or one of “hibernate”, “lockScreen”, “nothing”, “showLogoutScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.powerProfile
The Power Profile to enter in this mode.

Type: null or one of “performance”, “balanced”, “powerSaving”

Default: null

Example: "powerSaving"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.turnOffDisplay.idleTimeout
The duration (in seconds), when on AC, the computer, when unlocked, must be idle for until the display turns off.

Type: null or value “never” (singular enum) or integer between 30 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.turnOffDisplay.idleTimeoutWhenLocked
The duration (in seconds), when on AC, the computer must be idle (when locked) until the display turns off.

Type: null or one of “whenLockedAndUnlocked”, “immediately” or integer between 20 and 600000 (both inclusive)

Default: null

Example: 60

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.whenLaptopLidClosed
The action, when on AC, to perform when the laptop lid is closed.

Type: null or one of “doNothing”, “hibernate”, “lockScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "shutDown"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.AC.whenSleepingEnter
The state, when on AC, to enter when sleeping.

Type: null or one of “hybridSleep”, “standby”, “standbyThenHibernate”

Default: null

Example: "standbyThenHibernate"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.autoSuspend.action
The action, when on battery, to perform after a certain period of inactivity.

Type: null or one of “hibernate”, “nothing”, “shutDown”, “sleep”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.autoSuspend.idleTimeout
The duration (in seconds), when on battery, the computer must be idle for until the auto-suspend action is executed.

Type: null or integer between 60 and 600000 (both inclusive)

Default: null

Example: 600

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.dimDisplay.enable
Whether to enable screen dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.dimDisplay.idleTimeout
The duration (in seconds), when on battery, the computer must be idle until the display starts dimming.

Type: null or integer between 20 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.dimKeyboard.enable
Whether to enable keyboard backlight dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.displayBrightness
The brightness to set the display to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.inhibitLidActionWhenExternalMonitorConnected
If enabled, the lid action will be inhibited when an external monitor is connected.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.keyboardBrightness
The brightness to set the keyboard backlight to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.powerButtonAction
The action, when on battery, to perform when the power button is pressed.

Type: null or one of “hibernate”, “lockScreen”, “nothing”, “showLogoutScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.powerProfile
The Power Profile to enter in this mode.

Type: null or one of “performance”, “balanced”, “powerSaving”

Default: null

Example: "powerSaving"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.turnOffDisplay.idleTimeout
The duration (in seconds), when on battery, the computer, when unlocked, must be idle for until the display turns off.

Type: null or value “never” (singular enum) or integer between 30 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.turnOffDisplay.idleTimeoutWhenLocked
The duration (in seconds), when on battery, the computer must be idle (when locked) until the display turns off.

Type: null or one of “whenLockedAndUnlocked”, “immediately” or integer between 20 and 600000 (both inclusive)

Default: null

Example: 60

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.whenLaptopLidClosed
The action, when on battery, to perform when the laptop lid is closed.

Type: null or one of “doNothing”, “hibernate”, “lockScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "shutDown"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.battery.whenSleepingEnter
The state, when on battery, to enter when sleeping.

Type: null or one of “hybridSleep”, “standby”, “standbyThenHibernate”

Default: null

Example: "standbyThenHibernate"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.batteryLevels.criticalAction
The action to perform when Critical Battery Level is reached.

Type: null or one of “hibernate”, “nothing”, “shutDown”, “sleep”

Default: null

Example: "shutDown"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.batteryLevels.criticalLevel
The battery level considered “critical” for the laptop.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 2

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.batteryLevels.lowLevel
The battery level considered “low” for the laptop.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.general.pausePlayersOnSuspend
If enabled, pause media players when the system is suspended.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.autoSuspend.action
The action, when on lowBattery, to perform after a certain period of inactivity.

Type: null or one of “hibernate”, “nothing”, “shutDown”, “sleep”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.autoSuspend.idleTimeout
The duration (in seconds), when on lowBattery, the computer must be idle for until the auto-suspend action is executed.

Type: null or integer between 60 and 600000 (both inclusive)

Default: null

Example: 600

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.dimDisplay.enable
Whether to enable screen dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.dimDisplay.idleTimeout
The duration (in seconds), when on lowBattery, the computer must be idle until the display starts dimming.

Type: null or integer between 20 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.dimKeyboard.enable
Whether to enable keyboard backlight dimming.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.displayBrightness
The brightness to set the display to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.inhibitLidActionWhenExternalMonitorConnected
If enabled, the lid action will be inhibited when an external monitor is connected.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.keyboardBrightness
The brightness to set the keyboard backlight to in this mode.

Type: null or integer between 0 and 100 (both inclusive)

Default: null

Example: 10

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.powerButtonAction
The action, when on lowBattery, to perform when the power button is pressed.

Type: null or one of “hibernate”, “lockScreen”, “nothing”, “showLogoutScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "nothing"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.powerProfile
The Power Profile to enter in this mode.

Type: null or one of “performance”, “balanced”, “powerSaving”

Default: null

Example: "powerSaving"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.turnOffDisplay.idleTimeout
The duration (in seconds), when on lowBattery, the computer, when unlocked, must be idle for until the display turns off.

Type: null or value “never” (singular enum) or integer between 30 and 600000 (both inclusive)

Default: null

Example: 300

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.turnOffDisplay.idleTimeoutWhenLocked
The duration (in seconds), when on lowBattery, the computer must be idle (when locked) until the display turns off.

Type: null or one of “whenLockedAndUnlocked”, “immediately” or integer between 20 and 600000 (both inclusive)

Default: null

Example: 60

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.whenLaptopLidClosed
The action, when on lowBattery, to perform when the laptop lid is closed.

Type: null or one of “doNothing”, “hibernate”, “lockScreen”, “shutDown”, “sleep”, “turnOffScreen”

Default: null

Example: "shutDown"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.powerdevil.lowBattery.whenSleepingEnter
The state, when on lowBattery, to enter when sleeping.

Type: null or one of “hybridSleep”, “standby”, “standbyThenHibernate”

Default: null

Example: "standbyThenHibernate"

Declared by:

<plasma-manager/modules/powerdevil.nix>
programs.plasma.resetFiles
Configuration files which should be explicitly deleted on each generation.

Type: list of string

Default: [ ]

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.resetFilesExclude
Configuration files which explicitly should not be deleted on each generation, if overrideConfig is enabled.

Type: list of string

Default: [ ]

Declared by:

<plasma-manager/modules/files.nix>
programs.plasma.session.general.askForConfirmationOnLogout
Whether to ask for confirmation when shutting down, restarting or logging out

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/session.nix>
programs.plasma.session.sessionRestore.excludeApplications
List of applications to exclude from session restore

Type: null or (list of string)

Default: null

Example:

[
  "firefox"
  "xterm"
]
Declared by:

<plasma-manager/modules/session.nix>
programs.plasma.session.sessionRestore.restoreOpenApplicationsOnLogin
Controls how applications are restored on login:

“onLastLogout”: Restores applications that were open during the last logout.

“whenSessionWasManuallySaved”: Restores applications based on a manually saved session.

“startWithEmptySession”: Starts with a clean, empty session each time.

Type: null or one of “onLastLogout”, “startWithEmptySession”, “whenSessionWasManuallySaved”

Default: null

Example: "startWithEmptySession"

Declared by:

<plasma-manager/modules/session.nix>
programs.plasma.shortcuts
An attribute set where the keys are application groups and the values are shortcuts.

Type: attribute set of attribute set of ((list of string) or string)

Default: { }

Declared by:

<plasma-manager/modules/shortcuts.nix>
programs.plasma.spectacle.shortcuts.captureActiveWindow
The shortcut for capturing the active window.

Type: null or (list of string) or string

Default: null

Example: "Meta+Print"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.captureCurrentMonitor
The shortcut for capturing the current monitor.

Type: null or (list of string) or string

Default: null

Example: "Print"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.captureEntireDesktop
The shortcut for capturing the entire desktop.

Type: null or (list of string) or string

Default: null

Example: "Shift+Print"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.captureRectangularRegion
The shortcut for capturing a rectangular region.

Type: null or (list of string) or string

Default: null

Example: "Meta+Shift+S"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.captureWindowUnderCursor
The shortcut for capturing the window under the cursor.

Type: null or (list of string) or string

Default: null

Example: "Meta+Ctrl+Print"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.launch
The shortcut for launching Spectacle.

Type: null or (list of string) or string

Default: null

Example: "Meta+S"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.launchWithoutCapturing
The shortcut for launching Spectacle without capturing.

Type: null or (list of string) or string

Default: null

Example: "Meta+Alt+S"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.recordRegion
The shortcut for recording a region on the screen.

Type: null or (list of string) or string

Default: null

Example: "Meta+Shift+R"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.recordScreen
The shortcut for selecting a screen to record.

Type: null or (list of string) or string

Default: null

Example: "Meta+Alt+R"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.spectacle.shortcuts.recordWindow
The shortcut for selecting a window to record.

Type: null or (list of string) or string

Default: null

Example: "Meta+Ctrl+R"

Declared by:

<plasma-manager/modules/spectacle.nix>
programs.plasma.startup.dataDir
The name of the subdirectory where the datafiles should be.

Type: string

Default: "data"

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.dataFile
Datafiles, typically for use in autostart scripts.

Type: attribute set of string

Default: { }

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript
Plasma desktop scripts to be run exactly once at startup. See the KDE Documentation for details on Plasma desktop scripts.

Type: attribute set of (submodule)

Default: { }

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.postCommands
Commands to run after the desktop script lines.

Type: string

Default: ""

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.preCommands
Commands to run before the desktop script lines.

Type: string

Default: ""

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.priority
The priority for the execution of the script. Lower priority means earlier execution.

Type: integer between 0 and 8 (both inclusive)

Default: 0

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.restartServices
Services to restart after the script has been run.

Type: list of string

Default: [ ]

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.runAlways
When enabled the script will run even if no changes have been made since last successful run.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.desktopScript.<name>.text
The content of the startup script.

Type: string

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.scriptsDir
The name of the subdirectory where the scripts should be.

Type: string

Default: "scripts"

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.startupScript
Commands/scripts to be run at startup.

Type: attribute set of (submodule)

Default: { }

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.startupScript.<name>.priority
The priority for the execution of the script. Lower priority means earlier execution.

Type: integer between 0 and 8 (both inclusive)

Default: 0

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.startupScript.<name>.restartServices
Services to restart after the script has been run.

Type: list of string

Default: [ ]

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.startupScript.<name>.runAlways
When enabled the script will run even if no changes have been made since last successful run.

Type: boolean

Default: false

Example: true

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.startup.startupScript.<name>.text
The content of the startup script.

Type: string

Declared by:

<plasma-manager/modules/startup.nix>
programs.plasma.window-rules
KWin window rules.

Type: list of (submodule)

Default: [ ]

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.apply
Values to apply.

Type: attribute set of ((submodule) or (boolean or floating point number or signed integer or string) convertible to it)

Default: { }

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.apply.<name>.apply
How to apply the value.

Type: one of “do-not-affect”, “force”, “initially”, “remember”

Default: "initially"

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.apply.<name>.value
Value to set.

Type: boolean or floating point number or signed integer or string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.description
Value to set.

Type: string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match
This option has no description.

Type: submodule

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.machine
clientmachine matching.

Type: null or ((submodule) or string convertible to it)

Default: null

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.machine.type
Name match type.

Type: one of “exact”, “regex”, “substring”

Default: "exact"

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.machine.value
Name to match.

Type: string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.title
Title matching.

Type: null or ((submodule) or string convertible to it)

Default: null

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.title.type
Name match type.

Type: one of “exact”, “regex”, “substring”

Default: "exact"

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.title.value
Name to match.

Type: string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-class
Window class matching.

Type: null or ((submodule) or string convertible to it)

Default: null

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-class.match-whole
Match whole name.

Type: boolean

Default: true

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-class.type
Name match type.

Type: one of “exact”, “regex”, “substring”

Default: "exact"

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-class.value
Name to match.

Type: string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-role
Window role matching.

Type: null or ((submodule) or string convertible to it)

Default: null

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-role.type
Name match type.

Type: one of “exact”, “regex”, “substring”

Default: "exact"

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-role.value
Name to match.

Type: string

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.window-rules.*.match.window-types
Window types to match.

Type: list of (one of “desktop”, “dialog”, “dock”, “menubar”, “normal”, “osd”, “spash”, “toolbar”, “torn-of-menu”, “utility”)

Default: [ ]

Declared by:

<plasma-manager/modules/window-rules.nix>
programs.plasma.windows.allowWindowsToRememberPositions
Allow apps to remember the positions of their own windows, if they support it.

Type: null or boolean

Default: null

Declared by:

<plasma-manager/modules/windows.nix>
programs.plasma.workspace.enableMiddleClickPaste
Whether clicking the middle mouse button pastes the clipboard content.

Type: null or boolean

Default: null

Example: false

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.clickItemTo
Whether clicking files or folders should open or select them.

Type: null or one of “open”, “select”

Default: null

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.colorScheme
The Plasma color scheme. Run plasma-apply-colorscheme --list-schemes for valid options.

Type: null or string

Default: null

Example: "BreezeDark"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor
Submodule for configuring the cursor appearance. The theme, size, cursor feedback, task manager feedback, and animation time are configurable.

Type: null or (submodule)

Default: null

Example:

{
  animationTime = 5;
  cursorFeedback = "Bouncing";
  size = 24;
  taskManagerFeedback = true;
  theme = "Breeze_Snow";
}
Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor.animationTime
The duration that the cursorFeedback and taskManagerFeedback run for.

Type: null or (positive integer, meaning >0)

Default: null

Example: 5

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor.cursorFeedback
The cursor feedback icon after launching an application.

Type: null or one of “Bouncing”, “Blinking”, “Static”, “None”

Default: null

Example: "Bouncing"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor.size
The size of the cursor. See the System Settings app for allowed sizes for each cursor theme.

Type: null or (positive integer, meaning >0)

Default: null

Example: 24

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor.taskManagerFeedback
The feedback wheel on an application icon after launching an application from the task manager.

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.cursor.theme
The Plasma cursor theme. Run plasma-apply-cursortheme --list-themes for valid options.

Type: null or string

Default: null

Example: "Breeze_Snow"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.iconTheme
The Plasma icon theme.

Type: null or string

Default: null

Example: "Papirus"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.lookAndFeel
The Plasma Global Theme. Run plasma-apply-lookandfeel --list for valid options.

Type: null or string

Default: null

Example: "org.kde.breezedark.desktop"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.soundTheme
The sound theme to use with Plasma.

Type: null or string

Default: null

Example: "freedesktop"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.splashScreen.engine
The engine for the splash screen theme. If not specified, Plasma will try to set an appropriate engine, but this may fail, in which case this option should be specified manually.

Type: null or string

Default: null

Example: "none"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.splashScreen.theme
The splash screen theme shown at login. To view all available values, see the Theme key in $HOME/.config/ksplashrc after imperatively applying the splash screen via the System Settings app. Can also be set to None to disable the splash screen altogether.

Type: null or string

Default: null

Example: "None"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.theme
The Plasma style. Run plasma-apply-desktoptheme --list-themes for valid options.

Type: null or string

Default: null

Example: "breeze-dark"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.tooltipDelay
The delay in milliseconds before an element’s tooltip is shown when hovered over.

Type: null or (positive integer, meaning >0)

Default: null

Example: 5

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaper
The Plasma desktop wallpaper. Can be either the path to an image file or a KPackage.

Type: null or absolute path or list of absolute path

Default: null

Example: "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Kay/contents/images/1080x1920.png"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperBackground
How to handle wallpaper background when there is empty space.

Type: null or (submodule)

Default: null

Example:

{
  blur = true;
}
Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperBackground.blur
Whether to blur the background

Type: null or boolean

Default: null

Example: true

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperBackground.color
Background color to use

Type: null or string

Default: null

Example: "219,99,99"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperFillMode
Defines how the wallpaper should be displayed on the screen. Applies only to wallpaper, wallpaperPictureOfTheDay or wallpaperSlideShow.

Type: null or one of “pad”, “preserveAspectCrop”, “preserveAspectFit”, “stretch”, “tile”, “tileHorizontally”, “tileVertically”

Default: null

Example: "stretch"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperPictureOfTheDay
Which plugin to fetch the Picture of the Day from.

Type: null or (submodule)

Default: null

Example:

{
  provider = "apod";
}
Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperPictureOfTheDay.provider
The provider for the Picture of the Day plugin.

Type: null or one of “apod”, “bing”, “flickr”, “natgeo”, “noaa”, “wcpotd”, “epod”, “simonstalenhag”

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperPictureOfTheDay.updateOverMeteredConnection
Whether to update the wallpaper on a metered connection.

Type: boolean

Default: false

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperPlainColor
Set the wallpaper using a plain color. Color is a comma-seperated R,G,B,A string. The alpha is optional (default is 256).

Type: null or string

Default: null

Example: "0,64,174,256"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperSlideShow
Submodule for configuring the wallpaper slideshow. Needs a directory with wallpapers and an interval length.

Type: null or (submodule)

Default: null

Example: { path = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/"; }

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperSlideShow.interval
The length between wallpaper switches.

Type: signed integer

Default: 300

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.wallpaperSlideShow.path
The path(s) where the wallpapers are located.

Type: absolute path or list of absolute path

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.widgetStyle
The widget style to use with Plasma.

Type: null or string

Default: null

Example: "breeze"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.windowDecorations.library
The library for the window decorations theme. To view all available values, see the library key in the org.kde.kdecoration2 section of $HOME/.config/kwinrc after imperatively applying the window decoration via the System Settings app.

Type: null or string

Default: null

Example: "org.kde.kwin.aurorae"

Declared by:

<plasma-manager/modules/workspace.nix>
programs.plasma.workspace.windowDecorations.theme
The window decorations theme. To view all available values, see the theme key in the org.kde.kdecoration2 section of $HOME/.config/kwinrc after imperatively applying the window decoration via the System Settings app.

Type: null or string

Default: null

Example: "__aurorae__svg__CatppuccinMocha-Modern"

Declared by:

<plasma-manager/modules/workspace.nix>
Prev 	 	 
Introduction 	Home	 
