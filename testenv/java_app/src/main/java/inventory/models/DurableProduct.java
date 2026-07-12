package inventory.models;

/** A durable good that never expires. */
public class DurableProduct extends Product {
    public DurableProduct(String sku, String name, int priceCents, Category category) {
        super(sku, name, priceCents, category);
    }

    @Override
    public boolean isSellable() {
        return priceCents() > 0;
    }
}
