package inventory.pricing;

import inventory.models.Product;

/** Immutable pairing of a product with its computed charge (record type). */
public record PricedLine(Product product, int quantity, int totalCents) {
    /** Per-unit price implied by this line, in cents. */
    public int unitCents() {
        return quantity == 0 ? 0 : totalCents / quantity;
    }
}
