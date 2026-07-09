using System;

namespace Inventory.Models
{
    /// <summary>Broad classification for a catalog item.</summary>
    public enum Category
    {
        Electronics,
        Grocery,
        Apparel,
        Misc
    }

    /// <summary>Lifecycle state of a customer order.</summary>
    public enum OrderStatus
    {
        Pending,
        Shipped,
        Delivered,
        Cancelled
    }

    /// <summary>Base type for anything stocked in the warehouse.</summary>
    public abstract class Product
    {
        /// <summary>Stable stock-keeping-unit identifier.</summary>
        public string Sku { get; }

        /// <summary>Human-readable product name.</summary>
        public string Name { get; set; }

        /// <summary>Unit price expressed in whole cents.</summary>
        public int PriceCents { get; set; }

        /// <summary>Catalog category the product belongs to.</summary>
        public Category Category { get; set; }

        /// <summary>Convenience view of the price in whole dollars.</summary>
        public int PriceDollars => PriceCents / 100;

        protected Product(string sku, string name, int priceCents, Category category)
        {
            Sku = sku;
            Name = name;
            PriceCents = priceCents;
            Category = category;
        }

        /// <summary>Shelf label shown to warehouse staff.</summary>
        public virtual string Label()
        {
            return Name + " [" + Sku + "]";
        }

        /// <summary>Whether the item can currently be sold.</summary>
        public abstract bool IsSellable();
    }

    /// <summary>A durable good that never expires.</summary>
    public class DurableProduct : Product
    {
        public DurableProduct(string sku, string name, int priceCents, Category category)
            : base(sku, name, priceCents, category)
        {
        }

        public override bool IsSellable()
        {
            return PriceCents > 0;
        }
    }

    /// <summary>A perishable good that spoils after a number of days.</summary>
    public class PerishableProduct : Product
    {
        /// <summary>Days remaining before the item spoils.</summary>
        public int ShelfLifeDays { get; set; }

        public PerishableProduct(string sku, string name, int priceCents, int shelfLifeDays)
            : base(sku, name, priceCents, Category.Grocery)
        {
            ShelfLifeDays = shelfLifeDays;
        }

        public override bool IsSellable()
        {
            return PriceCents > 0 && ShelfLifeDays > 0;
        }

        /// <summary>Perishables append their remaining shelf life to the label.</summary>
        public override string Label()
        {
            return base.Label() + " (" + ShelfLifeDays + "d)";
        }
    }

    /// <summary>A single line item inside a customer order.</summary>
    public class OrderLine
    {
        /// <summary>Product being ordered on this line.</summary>
        public Product Item { get; set; }

        /// <summary>Number of units requested.</summary>
        public int Quantity { get; set; }

        public OrderLine(Product item, int quantity)
        {
            Item = item;
            Quantity = quantity;
        }

        /// <summary>Extended price for this line, in cents.</summary>
        public int LineTotal()
        {
            return Item.PriceCents * Quantity;
        }

        /// <summary>Whether this line requests zero units (expression-bodied).</summary>
        public bool IsEmpty() => Quantity == 0;
    }

    // intentionally dead (fixture): no code constructs or references LegacyPriceTag.
    /// <summary>Obsolete price sticker kept only for a migration that never shipped.</summary>
    internal class LegacyPriceTag
    {
        public string Code { get; set; }

        public string Render()
        {
            return "$" + Code;
        }
    }
}
