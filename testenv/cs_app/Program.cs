using System;
using System.Collections.Generic;
using Inventory.Models;
using Inventory.Pricing;
using Inventory.Services;

// Nested namespace declaration (block form) — Inventory > App.
namespace Inventory
{
    namespace App
    {
        /// <summary>Console entry point that wires the inventory app together.</summary>
        public class Program
        {
            /// <summary>Seed a catalog, place one bulk order, and print the total.</summary>
            public static void Main()
            {
                var inventory = new InventoryService();
                SeedCatalog(inventory);

                IPricingStrategy pricing = new BulkPricing(3, 10);
                var orders = new OrderService(inventory, pricing);

                var basket = new List<OrderLine>
                {
                    new OrderLine(inventory.Find("SKU-1"), 5),
                    new OrderLine(inventory.Find("SKU-2"), 2)
                };

                int total = orders.PlaceOrder(basket);
                Console.WriteLine("order total (cents): " + total);

                foreach (var product in inventory.SellableProducts())
                {
                    Console.WriteLine("sellable: " + product.Label());
                }
            }

            /// <summary>Register a couple of representative products.</summary>
            private static void SeedCatalog(InventoryService inventory)
            {
                var laptop = new DurableProduct("SKU-1", "Laptop", 129900, Category.Electronics);
                var milk = new PerishableProduct("SKU-2", "Milk", 299, 7);
                inventory.Register(laptop);
                inventory.Register(milk);
            }
        }
    }
}
