using System;
using System.Collections.Generic;
using Inventory.Models;
// Using alias: `Money` is Inventory.Models.Category renamed at import.
using Money = Inventory.Models.Category;

namespace Inventory.Tricky
{
    /// <summary>Attribute applied to a method below.</summary>
    [AttributeUsage(AttributeTargets.Method)]
    public class AuditedAttribute : Attribute
    {
        public string Reason { get; }

        public AuditedAttribute(string reason)
        {
            Reason = reason;
        }
    }

    /// <summary>Delegate type stored in fields and properties.</summary>
    public delegate int Adjust(int cents);

    /// <summary>Enum whose behaviour lives in an extension method.</summary>
    public enum Tier
    {
        Basic,
        Premium
    }

    /// <summary>Extension methods: static methods that read as instance calls.</summary>
    public static class TierExtensions
    {
        public static string Label(this Tier tier)
        {
            return tier == Tier.Premium ? "premium" : "basic";
        }

        public static int Bonus(this Tier tier, int cents)
        {
            return tier == Tier.Premium ? cents / 10 : 0;
        }
    }

    /// <summary>Outer class with a nested class, a nested enum and an indexer.</summary>
    public class Ledger
    {
        /// <summary>Nested type: Inventory.Tricky.Ledger.Entry.</summary>
        public class Entry
        {
            public string Sku { get; set; }
            public int Cents { get; set; }

            public Entry(string sku, int cents)
            {
                Sku = sku;
                Cents = cents;
            }

            /// <summary>Nested-nested enum, three levels deep.</summary>
            public enum Kind
            {
                Debit,
                Credit
            }

            public Kind Direction()
            {
                return Cents < 0 ? Kind.Debit : Kind.Credit;
            }
        }

        private readonly List<Entry> _entries = new List<Entry>();

        /// <summary>Lambda stored in a field, called through the field.</summary>
        private readonly Adjust _round = cents => (cents / 10) * 10;

        /// <summary>Delegate-valued property with a getter and a setter.</summary>
        public Adjust Adjuster { get; set; }

        /// <summary>Indexer: an operator spelled like a property.</summary>
        public Entry this[int index]
        {
            get { return _entries[index]; }
        }

        /// <summary>Count of entries (expression-bodied read-only property).</summary>
        public int Count => _entries.Count;

        /// <summary>Three overloads of one name.</summary>
        public void Post(Entry entry)
        {
            _entries.Add(entry);
        }

        public void Post(string sku, int cents)
        {
            Post(new Entry(sku, cents));
        }

        public void Post(Product product, int quantity)
        {
            Post(product.Sku, product.PriceCents * quantity);
        }

        /// <summary>Signature split over three lines, with a default argument.</summary>
        public int Total(
            Tier tier = Tier.Basic,
            Adjust adjust = null)
        {
            int sum = 0;
            foreach (Entry entry in _entries)
            {
                sum += _round(entry.Cents);
            }
            Adjust chosen = adjust ?? Adjuster;
            if (chosen != null)
            {
                sum = chosen(sum);
            }
            return sum + tier.Bonus(sum);
        }
    }

    /// <summary>Generic class with a constraint and a static factory.</summary>
    public class Box<T> where T : class
    {
        private T _value;

        public Box(T value)
        {
            _value = value;
        }

        public T Value
        {
            get { return _value; }
            set { _value = value; }
        }

        public static Box<T> Of(T value)
        {
            return new Box<T>(value);
        }
    }

    /// <summary>Interface implemented both implicitly and explicitly below.</summary>
    public interface IRenderable
    {
        string Render();
    }

    /// <summary>Second interface, whose Render is implemented explicitly.</summary>
    public interface ICompact
    {
        string Render();
    }

    /// <summary>Base class with a virtual method and operator overloads.</summary>
    public class Slip : IRenderable, ICompact
    {
        public int Cents { get; set; }

        public Slip(int cents)
        {
            Cents = cents;
        }

        public virtual string Render()
        {
            return "slip:" + Cents;
        }

        /// <summary>Explicit interface implementation: only reachable through ICompact.</summary>
        string ICompact.Render()
        {
            return "c" + Cents;
        }

        public static Slip operator +(Slip left, Slip right)
        {
            return new Slip(left.Cents + right.Cents);
        }
    }

    /// <summary>Derived class calling into its base.</summary>
    public class TaggedSlip : Slip
    {
        public string Tag { get; set; }

        public TaggedSlip(int cents, string tag) : base(cents)
        {
            Tag = tag;
        }

        public override string Render()
        {
            return base.Render() + "#" + Tag;
        }
    }

    /// <summary>Drives every construct above from one place.</summary>
    public static class TrickyRunner
    {
        /// <summary>Code-shaped text in a verbatim string is data, not code.</summary>
        private const string Banner = @"
public class PhantomFromString { public void Ghost() { } }
public int PhantomMethod() => 0;
";

        // public class PhantomFromComment { public void Ghost() { } }

        [Audited("demo")]
        public static int Run()
        {
            var ledger = new Ledger();
            ledger.Post(new Ledger.Entry("SKU-1", 500));
            ledger.Post("SKU-2", 250);
            ledger.Post(new DurableProduct("SKU-3", "Cable", 99, Money.Electronics), 2);

            // Local function: a definition nested inside a method body.
            int Doubled(int cents)
            {
                return cents * 2;
            }

            ledger.Adjuster = Doubled;
            int total = ledger.Total(Tier.Premium);
            Ledger.Entry first = ledger[0];
            Ledger.Entry.Kind direction = first.Direction();

            Box<string> boxed = Box<string>.Of(Tier.Basic.Label());
            string label = boxed.Value;

            Slip plain = new Slip(total);
            Slip tagged = new TaggedSlip(total, label);
            Slip combined = plain + tagged;
            ICompact compact = plain;

            return combined.Cents + compact.Render().Length + Banner.Length +
                   ledger.Count + direction.GetHashCode();
        }
    }
}
