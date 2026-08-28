package inventory.models;

/** A single line item inside a customer order. */
public class OrderLine {
    private Product item;
    private int quantity;

    public OrderLine(Product item, int quantity) {
        this.item = item;
        this.quantity = quantity;
    }

    /** Product being ordered on this line. */
    public Product item() {
        return item;
    }

    /** Number of units requested. */
    public int quantity() {
        return quantity;
    }

    /** Extended price for this line, in cents. */
    public int lineTotal() {
        return item.priceCents() * quantity;
    }

    /** Whether this line requests zero units. */
    public boolean isEmpty() {
        return quantity == 0;
    }
}
