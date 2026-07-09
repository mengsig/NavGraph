using Inventory.Models;

namespace Inventory.Pricing
{
    /// <summary>Strategy for turning a product and quantity into a charge in cents.</summary>
    public interface IPricingStrategy
    {
        /// <summary>Total price, in cents, for <paramref name="quantity"/> units.</summary>
        int PriceFor(Product product, int quantity);

        /// <summary>Short human label describing the pricing rule.</summary>
        string Describe();
    }

    /// <summary>Charges list price with no adjustments.</summary>
    public class StandardPricing : IPricingStrategy
    {
        public int PriceFor(Product product, int quantity)
        {
            return product.PriceCents * quantity;
        }

        public string Describe()
        {
            return "standard";
        }
    }

    /// <summary>Applies a flat percentage discount above a quantity threshold.</summary>
    public class BulkPricing : IPricingStrategy
    {
        /// <summary>Minimum quantity at which the bulk discount kicks in.</summary>
        public int Threshold { get; set; }

        /// <summary>Percent taken off once the threshold is reached (0-100).</summary>
        public int DiscountPercent { get; set; }

        public BulkPricing(int threshold, int discountPercent)
        {
            Threshold = threshold;
            DiscountPercent = discountPercent;
        }

        public int PriceFor(Product product, int quantity)
        {
            int gross = product.PriceCents * quantity;
            if (quantity >= Threshold)
            {
                return Discounted(gross);
            }
            return gross;
        }

        public string Describe()
        {
            return "bulk";
        }

        // Private, but genuinely used by PriceFor above.
        private int Discounted(int cents)
        {
            int off = (cents * DiscountPercent) / 100;
            return cents - off;
        }
    }
}
