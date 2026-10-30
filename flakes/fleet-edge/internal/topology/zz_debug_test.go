package topology

import ("testing"; "fmt")

func TestZZDump(t *testing.T) {
	for name, d := range laneFixtures() {
		if name == "basic" { continue }
		fmt.Println("==", name, d.Width, d.Height)
		for _, c := range d.Columns { fmt.Println("col", c.ID, c.X, c.Y, c.W) }
		for _, n := range d.Nodes { fmt.Println("node", n.ID, n.X, n.Y, n.W, n.H, n.CenterX(), n.CenterY()) }
		for _, e := range d.Edges { fmt.Println("edge", e.From, e.To, e.D) }
		for _, l := range d.RouteLinks { fmt.Println("link", l.Group, l.ToID, l.D) }
	}
}
