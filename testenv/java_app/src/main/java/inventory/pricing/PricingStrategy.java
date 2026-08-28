package inventory.pricing;

import inventory.models.Product;

/** Strategy for turning a product and quantity into a charge in cents. */
public interface PricingStrategy {
    /** Total price, in cents, for {@code quantity} units. */
    int priceFor(Product product, int quantity);

    /** Short human label describing the pricing rule. */
    String describe();
}
