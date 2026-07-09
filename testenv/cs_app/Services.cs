using System;
using System.Collections.Generic;
using Inventory.Data;
using Inventory.Models;
using Inventory.Pricing;

namespace Inventory.Services
{
    /// <summary>Coordinates the product catalog on top of a repository.</summary>
    public class InventoryService
    {
        private readonly IRepository<Product> _products;

        public InventoryService()
        {
            _products = new Repository<Product>();
        }

        /// <summary>Add a product to the catalog under its SKU.</summary>
        public void Register(Product product)
        {
            _audit("register", product);
            _products.Add(product.Sku, product);
        }

        /// <summary>Look a product up by SKU, or null when unknown.</summary>
        public Product Find(string sku)
        {
            return _products.Get(sku);
        }

        /// <summary>All catalog products that are currently sellable.</summary>
        public List<Product> SellableProducts()
        {
            var all = _products.All();
            var result = new List<Product>();
            foreach (var product in all)
            {
                if (product.IsSellable())
                {
                    result.Add(product);
                }
            }
            return result;
        }

        // Private helper that IS called (by Register) — should not be flagged dead.
        private void _audit(string action, Product product)
        {
            Console.WriteLine("[audit] " + action + " " + product.Label());
        }

        // intentionally dead (fixture): nothing calls _rebuildIndex.
        private void _rebuildIndex()
        {
            var snapshot = _products.All();
            foreach (var product in snapshot)
            {
                _products.Add(product.Sku, product);
            }
        }
    }

    /// <summary>Turns baskets into priced orders using a pricing strategy.</summary>
    public class OrderService
    {
        private readonly InventoryService _inventory;
        private readonly IPricingStrategy _pricing;

        /// <summary>Next order id to hand out; shared across the process.</summary>
        public static int NextOrderId = 1000;

        public OrderService(InventoryService inventory, IPricingStrategy pricing)
        {
            _inventory = inventory;
            _pricing = pricing;
        }

        /// <summary>Price a basket of (SKU, quantity) pairs and return the total in cents.</summary>
        public int PlaceOrder(List<OrderLine> lines)
        {
            int total = 0;
            foreach (var line in lines)
            {
                Product resolved = _inventory.Find(line.Item.Sku);
                if (resolved == null)
                {
                    continue;
                }
                total = total + _pricing.PriceFor(resolved, line.Quantity);
            }
            NextOrderId = NextOrderId + 1;
            return total;
        }

        /// <summary>Build an order line for a SKU that is known to the catalog.</summary>
        public OrderLine LineFor(string sku, int quantity)
        {
            Product product = _inventory.Find(sku);
            return new OrderLine(product, quantity);
        }
    }
}
