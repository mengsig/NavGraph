package inventory.pricing;

import inventory.models.Product;

/** Applies a flat percentage discount above a quantity threshold. */
public class BulkPricing implements PricingStrategy {
    private final int threshold;
    private final int discountPercent;

    public BulkPricing(int threshold, int discountPercent) {
        this.threshold = threshold;
        this.discountPercent = discountPercent;
    }

    @Override
    public int priceFor(Product product, int quantity) {
        int gross = product.priceCents() * quantity;
        if (quantity >= threshold) {
            return discounted(gross);
        }
        return gross;
    }

    @Override
    public String describe() {
        return "bulk";
    }

    // Private, but genuinely used by priceFor above.
    private int discounted(int cents) {
        int off = (cents * discountPercent) / 100;
        return cents - off;
    }
}
