// Package tricky collects the Go constructs that break heuristic parsers.
// Nothing in the service imports it: tests/golden/go.json records exactly which
// definitions and reference edges a correct indexer must find here.
package tricky

import (
	"fmt"
	"sort"
	"strings"

	"github.com/example/go_service/models"
	// Aliased import of a package already imported elsewhere under its own name.
	st "github.com/example/go_service/store"
)

// Budget is a package-level constant a local below shadows.
const Budget = 16

// Sizes uses iota with an expression, not a plain sequence.
const (
	Small  = 1 << iota // 1
	Medium             // 2
	Large              // 4
)

// Named function type: Go's function-in-a-variable shape.
type Adjust func(cents int) int

// Named slice type carrying its own methods.
type Widgets []models.Widget

// Len, Less and Swap make Widgets satisfy sort.Interface.
func (ws Widgets) Len() int { return len(ws) }

func (ws Widgets) Less(i, j int) bool { return ws[i].Name < ws[j].Name }

func (ws Widgets) Swap(i, j int) { ws[i], ws[j] = ws[j], ws[i] }

// Names collects every widget name. Value receiver on a named slice type.
func (ws Widgets) Names() []string {
	out := make([]string, 0, len(ws))
	for _, w := range ws {
		out = append(out, w.Name)
	}
	return out
}

// Describer is the interface the ledger below embeds.
type Describer interface {
	Describe() string
}

// Auditor embeds another interface: Go's interface inheritance.
type Auditor interface {
	Describer
	Audit(reason string) string
}

// base carries the fields an embedding struct promotes.
type base struct {
	owner string
	count int
}

// Describe is promoted onto every struct embedding base.
func (b base) Describe() string {
	return fmt.Sprintf("%s/%d", b.owner, b.count)
}

// Ledger embeds base, so base's method set is promoted onto it.
type Ledger struct {
	base
	widgets Widgets
	adjust  Adjust
	store   st.Store `json:"-"`
}

// NewLedger builds a Ledger with a closure bound to its adjust field.
func NewLedger(owner string, store st.Store) *Ledger {
	return &Ledger{
		base:   base{owner: owner},
		adjust: func(cents int) int { return cents * 2 },
		store:  store,
	}
}

// Audit completes the Auditor interface alongside the promoted Describe.
func (l *Ledger) Audit(reason string) string {
	return l.Describe() + ":" + reason
}

// Post appends a widget and returns the new count. Named return values.
func (l *Ledger) Post(w models.Widget) (count int, err error) {
	if err = w.Validate(); err != nil {
		return l.count, err
	}
	l.widgets = append(l.widgets, w)
	l.count = len(l.widgets)
	return l.count, nil
}

// Sorted returns the widget names in order, driving the sort.Interface methods.
func (l *Ledger) Sorted() []string {
	sort.Sort(l.widgets)
	return l.widgets.Names()
}

// Total applies the closure held in the adjust field.
func (l *Ledger) Total(cents int) int {
	if l.adjust == nil {
		return cents
	}
	return l.adjust(cents)
}

// Map is a generic helper with a type parameter and a constraint.
func Map[T any, R any](in []T, f func(T) R) []R {
	out := make([]R, 0, len(in))
	for _, v := range in {
		out = append(out, f(v))
	}
	return out
}

// Number constrains Sum's element type.
type Number interface {
	~int | ~int64 | ~float64
}

// Sum is generic over any Number.
func Sum[T Number](values ...T) T {
	var total T
	for _, v := range values {
		total += v
	}
	return total
}

// Classify uses a type switch over an empty interface.
func Classify(v any) string {
	switch typed := v.(type) {
	case models.Widget:
		return typed.Name
	case Widgets:
		return strings.Join(typed.Names(), ",")
	case error:
		return typed.Error()
	default:
		return "unknown"
	}
}

// double is referenced only through the package-level variable below.
func double(cents int) int { return cents * 2 }

// Doubler holds a function by name: a call through it reaches double.
var Doubler Adjust = double

// ShadowBudget's local Budget hides the package-level one.
func ShadowBudget(n int) int {
	Budget := 4
	return n * Budget
}

// Banner holds code-shaped text: data, never symbols.
const Banner = `
func phantomFromString() {}
type PhantomStruct struct{ X int }
`

// func phantomFromComment() {}

// parseID shares its name with handlers.parseID: two package-private functions,
// one name, two packages.
func parseID(raw string) (models.WidgetID, error) {
	if raw == "" {
		return 0, models.ErrInvalid
	}
	return models.WidgetID(len(raw)), nil
}

// Run drives every construct above from one place.
func Run(store st.Store) string {
	ledger := NewLedger("root", store)

	widget := models.Widget{Name: "bolt", Status: models.StatusActive}
	widget.Touch(widget.CreatedAt)
	if _, err := ledger.Post(widget); err != nil {
		return err.Error()
	}

	names := ledger.Sorted()
	lengths := Map(names, func(s string) int { return len(s) })
	total := Sum(lengths...)

	id, err := parseID(widget.Name)
	if err != nil {
		return err.Error()
	}

	kind := Classify(widget) + Classify(ledger.widgets)
	audited := ledger.Audit(widget.Status.String())

	return fmt.Sprintf("%s %s %d %d %d %d %d",
		kind, audited, id, total,
		ledger.Total(Doubler(ShadowBudget(Budget))),
		len(Banner), Small+Medium+Large)
}
