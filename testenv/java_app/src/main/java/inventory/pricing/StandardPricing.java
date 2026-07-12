package inventory.pricing;

import inventory.models.Product;

/** Charges list price with no adjustments. */
public class StandardPricing implements PricingStrategy {
    @Override
    public int priceFor(Product product, int quantity) {
        return product.priceCents() * quantity;
    }

    @Override
    public String describe() {
        return "standard";
    }
}
