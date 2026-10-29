package diff

import "testing"

func TestParseNumbersLines(t *testing.T) {
	raw := `diff --git a/f b/f
index 111..222 100644
--- a/f
+++ b/f
@@ -10,3 +10,4 @@ func x()
 ctx1
-old
+new
+added
 ctx2
`
	res := Parse(raw)
	if res.Truncated {
		t.Fatal("unexpected truncation")
	}
	want := []struct {
		kind         string
		oldNo, newNo int
		text         string
	}{
		{"meta", 0, 0, "diff --git a/f b/f"},
		{"meta", 0, 0, "index 111..222 100644"},
		{"meta", 0, 0, "--- a/f"},
		{"meta", 0, 0, "+++ b/f"},
		{"hunk", 0, 0, "@@ -10,3 +10,4 @@ func x()"},
		{"ctx", 10, 10, " ctx1"},
		{"del", 11, 0, "-old"},
		{"add", 0, 11, "+new"},
		{"add", 0, 12, "+added"},
		{"ctx", 12, 13, " ctx2"},
	}
	if len(res.Lines) != len(want) {
		t.Fatalf("got %d lines, want %d: %+v", len(res.Lines), len(want), res.Lines)
	}
	for i, w := range want {
		got := res.Lines[i]
		if got.Kind != w.kind || got.OldNo != w.oldNo || got.NewNo != w.newNo || got.Text != w.text {
			t.Errorf("line %d = %+v, want %+v", i, got, w)
		}
	}
}

func TestParseEmpty(t *testing.T) {
	if res := Parse(""); len(res.Lines) != 0 {
		t.Fatalf("got %+v", res)
	}
}

func TestParseTruncates(t *testing.T) {
	raw := ""
	for i := 0; i < maxLines+50; i++ {
		raw += "+line\n"
	}
	res := Parse(raw)
	if !res.Truncated {
		t.Fatal("expected truncation")
	}
	if len(res.Lines) > maxLines {
		t.Fatalf("kept %d lines", len(res.Lines))
	}
}

func TestSplitPairsChanges(t *testing.T) {
	raw := `@@ -1,3 +1,4 @@
 ctx
-old
+new
+added
 ctx2
`
	rows := Split(Parse(raw).Lines)
	// hunk, ctx, del/add pair, add pair, ctx2
	if len(rows) != 5 {
		t.Fatalf("got %d rows: %+v", len(rows), rows)
	}
	if rows[0].Kind != "hunk" {
		t.Fatalf("row 0 = %+v", rows[0])
	}
	if rows[1].Left.Text != "ctx" || rows[1].Right.Text != "ctx" || rows[1].Left.Kind != "ctx" {
		t.Fatalf("context row = %+v", rows[1])
	}
	if rows[2].Left.Kind != "del" || rows[2].Left.Text != "old" || rows[2].Left.No != 2 {
		t.Fatalf("del cell = %+v", rows[2].Left)
	}
	if rows[2].Right.Kind != "add" || rows[2].Right.Text != "new" || rows[2].Right.No != 2 {
		t.Fatalf("add cell = %+v", rows[2].Right)
	}
	// An addition with no matching deletion keeps the left side empty.
	if rows[3].Left.Kind != "empty" || rows[3].Left.No != 0 || rows[3].Right.Text != "added" {
		t.Fatalf("unpaired add = %+v", rows[3])
	}
}

func TestDisplayDropsPlumbing(t *testing.T) {
	raw := `diff --git a/f b/f
index 111..222 100644
--- a/f
+++ b/f
new file mode 100644
@@ -0,0 +1 @@
+x
`
	res := Display(Parse(raw))
	var kinds []string
	for _, l := range res.Lines {
		kinds = append(kinds, l.Kind+":"+l.Text)
	}
	want := []string{"meta:new file mode 100644", "hunk:@@ -0,0 +1 @@", "add:+x"}
	if len(kinds) != len(want) {
		t.Fatalf("got %v", kinds)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Fatalf("got %v, want %v", kinds, want)
		}
	}
}

func TestLineBodyAndSign(t *testing.T) {
	res := Parse("@@ -1 +1 @@\n-a\n+b\n c\n")
	got := []string{}
	for _, l := range res.Lines {
		got = append(got, l.Sign()+"|"+l.Body())
	}
	want := []string{"|@@ -1 +1 @@", "-|a", "+|b", "|c"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}
