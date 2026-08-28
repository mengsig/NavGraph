package inventory.app;

import java.util.ArrayList;
import java.util.List;

import static inventory.util.Money.format;

import inventory.models.Category;
import inventory.models.DurableProduct;
import inventory.models.OrderLine;
import inventory.models.PerishableProduct;
import inventory.models.Product;
import inventory.pricing.BulkPricing;
import inventory.pricing.PricingStrategy;
import inventory.services.InventoryService;
import inventory.services.OrderService;

/** Console entry point that wires the inventory app together. */
public class Program {
    /** Seed a catalog, place one bulk order, and print the total. */
    public static void main(String[] args) {
        InventoryService inventory = new InventoryService();
        seedCatalog(inventory);

        PricingStrategy pricing = new BulkPricing(3, 10);
        OrderService orders = new OrderService(inventory, pricing);

        List<OrderLine> basket = new ArrayList<>();
        basket.add(new OrderLine(inventory.find("SKU-1"), 5));
        basket.add(new OrderLine(inventory.find("SKU-2"), 2));

        int total = orders.placeOrderSafe(basket);
        System.out.println("order total: " + format(total));

        for (Product product : inventory.sellableProducts()) {
            System.out.println("sellable: " + product.label());
        }
    }

    /** Register a couple of representative products. */
    private static void seedCatalog(InventoryService inventory) {
        DurableProduct laptop = new DurableProduct("SKU-1", "Laptop", 129900, Category.ELECTRONICS);
        PerishableProduct milk = new PerishableProduct("SKU-2", "Milk", 299, 7);
        inventory.register(laptop);
        inventory.register(milk);
    }
}
