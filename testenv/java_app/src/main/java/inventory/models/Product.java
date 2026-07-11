package inventory.models;

/** Base type for anything stocked in the warehouse. */
public abstract class Product {
    private final String sku;
    private String name;
    private int priceCents;
    private Category category;

    protected Product(String sku, String name, int priceCents, Category category) {
        this.sku = sku;
        this.name = name;
        this.priceCents = priceCents;
        this.category = category;
    }

    /** Stable stock-keeping-unit identifier. */
    public String sku() {
        return sku;
    }

    /** Human-readable product name. */
    public String name() {
        return name;
    }

    /** Unit price expressed in whole cents. */
    public int priceCents() {
        return priceCents;
    }

    /** Catalog category the product belongs to. */
    public Category category() {
        return category;
    }

    /** Convenience view of the price in whole dollars. */
    public int priceDollars() {
        return priceCents / 100;
    }

    /** Shelf label shown to warehouse staff. */
    public String label() {
        return name + " [" + sku + "]";
    }

    /** Whether the item can currently be sold. */
    public abstract boolean isSellable();
}
