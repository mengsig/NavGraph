package inventory.services;

/** Raised when an order cannot be priced or fulfilled. */
public class OrderException extends Exception {
    public OrderException(String message) {
        super(message);
    }
}
