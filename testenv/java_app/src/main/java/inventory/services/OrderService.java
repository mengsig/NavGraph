package inventory.services;

import java.util.List;

import inventory.models.OrderLine;
import inventory.models.Product;
import inventory.pricing.PricedLine;
import inventory.pricing.PricingStrategy;

/** Turns baskets into priced orders using a pricing strategy. */
public class OrderService {
    private final InventoryService inventory;
    private final PricingStrategy pricing;

    /** Next order id to hand out; shared across the process. */
    public static int nextOrderId = 1000;

    public OrderService(InventoryService inventory, PricingStrategy pricing) {
        this.inventory = inventory;
        this.pricing = pricing;
    }

    /** Price a basket and return the total in cents, or fail on an unknown SKU. */
    public int placeOrder(List<OrderLine> lines) throws OrderException {
        int total = 0;
        for (OrderLine line : lines) {
            Product resolved = inventory.find(line.item().sku());
            if (resolved == null) {
                throw new OrderException("unknown sku: " + line.item().sku());
            }
            total = total + pricing.priceFor(resolved, line.quantity());
        }
        nextOrderId = nextOrderId + 1;
        return total;
    }

    /** Price a basket, swallowing failures into a zero total. */
    public int placeOrderSafe(List<OrderLine> lines) {
        try {
            return placeOrder(lines);
        } catch (OrderException e) {
            System.out.println("order failed: " + e.getMessage());
            return 0;
        }
    }

    /** Build a priced line for a SKU that is known to the catalog. */
    public PricedLine priceLine(String sku, int quantity) {
        Product product = inventory.find(sku);
        int total = pricing.priceFor(product, quantity);
        return new PricedLine(product, quantity, total);
    }
}
