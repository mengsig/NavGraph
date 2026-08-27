package inventory.tricky;

import java.util.ArrayList;
import java.util.List;
import java.util.function.IntUnaryOperator;

import static inventory.util.Money.dollars;

import inventory.models.Category;
import inventory.models.DurableProduct;
import inventory.models.Product;

/** Constructs that break heuristic parsers, gathered in one file. */
public final class Tricky {
    /** Class constant a local below shadows. */
    public static final int BUDGET = 16;

    /** Enum with its own constructor, field and method. */
    public enum Tier {
        BASIC(0),
        PREMIUM(10);

        private final int bonusPercent;

        Tier(int bonusPercent) {
            this.bonusPercent = bonusPercent;
        }

        /** Bonus applied to a cents amount at this tier. */
        public int bonus(int cents) {
            return cents * bonusPercent / 100;
        }
    }

    /** Interface with a default method and a static method. */
    public interface Renderable {
        String render();

        /** Default method built on {@link #render()}. */
        default String renderLoud() {
            return render().toUpperCase();
        }

        /** Static interface method. */
        static Renderable of(String text) {
            return () -> text;
        }
    }

    /** Static nested class, itself holding an inner (non-static) class. */
    public static class Ledger implements Renderable {
        private final String owner;
        private final List<Entry> entries = new ArrayList<>();
        private IntUnaryOperator adjust = cents -> cents;

        /** Inner class: it captures the enclosing Ledger instance. */
        public class Entry {
            private final String label;
            private final int cents;

            public Entry(String label, int cents) {
                this.label = label;
                this.cents = cents;
            }

            /** Reaches the enclosing instance's field through Ledger.this. */
            public String describe() {
                return Ledger.this.owner + "/" + label + "=" + cents;
            }

            public int cents() {
                return cents;
            }
        }

        public Ledger(String owner) {
            this.owner = owner;
        }

        /** Three overloads of one name. */
        public Entry post(String label, int cents) {
            Entry entry = new Entry(label, cents);
            entries.add(entry);
            return entry;
        }

        public Entry post(Product product, int quantity) {
            return post(product.sku(), product.priceCents() * quantity);
        }

        public Entry post(Entry entry) {
            entries.add(entry);
            return entry;
        }

        /** Varargs, plus a call through the lambda held in a field. */
        public int total(Tier tier, int... extra) {
            int sum = 0;
            for (Entry entry : entries) {
                sum += adjust.applyAsInt(entry.cents());
            }
            for (int value : extra) {
                sum += value;
            }
            return sum + tier.bonus(sum);
        }

        /** Setter for the lambda field. */
        public void adjustWith(IntUnaryOperator operator) {
            adjust = operator;
        }

        @Override
        public String render() {
            return owner + ":" + entries.size();
        }

        public int size() {
            return entries.size();
        }
    }

    /** Subclass calling into its base through super. */
    public static class TaggedLedger extends Ledger {
        private final String tag;

        public TaggedLedger(String owner, String tag) {
            super(owner);
            this.tag = tag;
        }

        @Override
        public String render() {
            return super.render() + "#" + tag;
        }
    }

    /** Generic method with a bound, mirroring inventory.data.Query.where. */
    public static <T extends Product> List<T> sellable(List<T> items) {
        List<T> matched = new ArrayList<>();
        for (T item : items) {
            if (item.isSellable()) {
                matched.add(item);
            }
        }
        return matched;
    }

    /** Record with a compact body. */
    public record Slip(String sku, int cents) {
        /** Whole dollars for this slip, via the statically imported helper. */
        public int asDollars() {
            return dollars(cents);
        }
    }

    private static int doubleValue(int value) {
        return value * 2;
    }

    /** A method reference held in a field: calls through it reach doubleValue. */
    private static final IntUnaryOperator DOUBLER = Tricky::doubleValue;

    /** The local BUDGET hides the class constant. */
    public static int shadowBudget(int n) {
        int BUDGET = 4;
        return n * BUDGET;
    }

    /** Code-shaped text in a text block and in comments: data, not symbols. */
    private static final String BANNER = """
            public class PhantomClass {
                public void ghost() {}
            }
            public int phantomFromString() { return 0; }
            """;

    // public class PhantomFromComment { public void ghost() {} }

    private Tricky() {
    }

    /** Drives every construct above from one place. */
    public static String run() {
        Ledger ledger = new Ledger("root");
        Ledger.Entry first = ledger.post("a", 500);
        ledger.post(first);

        Product laptop = new DurableProduct("SKU-9", "Laptop", 129900, Category.ELECTRONICS);
        ledger.post(laptop, 2);
        ledger.adjustWith(DOUBLER);

        TaggedLedger tagged = new TaggedLedger("root", "t");
        String rendered = tagged.render() + tagged.renderLoud();

        // Anonymous class implementing the interface.
        Renderable anon = new Renderable() {
            @Override
            public String render() {
                return "anon";
            }
        };

        List<Product> stock = new ArrayList<>();
        stock.add(laptop);
        List<Product> live = sellable(stock);

        Slip slip = new Slip(laptop.sku(), ledger.total(Tier.PREMIUM, 1, 2, 3));

        return String.join(" ",
                first.describe(),
                rendered,
                anon.renderLoud(),
                Renderable.of("x").render(),
                Integer.toString(slip.asDollars()),
                Integer.toString(live.size()),
                Integer.toString(ledger.size()),
                Integer.toString(shadowBudget(BUDGET)),
                Integer.toString(BANNER.length()));
    }
}
