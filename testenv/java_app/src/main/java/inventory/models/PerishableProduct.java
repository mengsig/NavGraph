package inventory.models;

/** A perishable good that spoils after a number of days. */
public class PerishableProduct extends Product {
    private int shelfLifeDays;

    public PerishableProduct(String sku, String name, int priceCents, int shelfLifeDays) {
        super(sku, name, priceCents, Category.GROCERY);
        this.shelfLifeDays = shelfLifeDays;
    }

    /** Days remaining before the item spoils. */
    public int shelfLifeDays() {
        return shelfLifeDays;
    }

    @Override
    public boolean isSellable() {
        return priceCents() > 0 && shelfLifeDays > 0;
    }

    /** Perishables append their remaining shelf life to the label. */
    @Override
    public String label() {
        return super.label() + " (" + shelfLifeDays + "d)";
    }
}
