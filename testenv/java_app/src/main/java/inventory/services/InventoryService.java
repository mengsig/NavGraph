package inventory.services;

import java.util.ArrayList;
import java.util.List;

import inventory.data.InMemoryRepository;
import inventory.data.Repository;
import inventory.models.Product;

/** Coordinates the product catalog on top of a repository. */
public class InventoryService {
    private final Repository<Product> products;

    public InventoryService() {
        products = new InMemoryRepository<>();
    }

    /** Add a product to the catalog under its SKU. */
    public void register(Product product) {
        audit("register", product);
        products.add(product.sku(), product);
    }

    /** Look a product up by SKU, or null when unknown. */
    public Product find(String sku) {
        return products.get(sku);
    }

    /** All catalog products that are currently sellable. */
    public List<Product> sellableProducts() {
        List<Product> result = new ArrayList<>();
        for (Product product : products.all()) {
            if (product.isSellable()) {
                result.add(product);
            }
        }
        return result;
    }

    // Private helper that IS called (by register) — should not be flagged dead.
    private void audit(String action, Product product) {
        System.out.println("[audit] " + action + " " + product.label());
    }

    // intentionally dead (fixture): nothing calls rebuildIndex.
    private void rebuildIndex() {
        for (Product product : products.all()) {
            products.add(product.sku(), product);
        }
    }
}
