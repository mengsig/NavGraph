using System;
using System.Collections.Generic;

namespace Inventory.Data
{
    /// <summary>Generic key/value store contract used by the service layer.</summary>
    public interface IRepository<T>
    {
        /// <summary>Insert or replace the item stored under <paramref name="key"/>.</summary>
        void Add(string key, T item);

        /// <summary>Fetch the item for <paramref name="key"/>, or default when absent.</summary>
        T Get(string key);

        /// <summary>Enumerate every stored item.</summary>
        List<T> All();

        /// <summary>Remove the item under <paramref name="key"/>; true when present.</summary>
        bool Remove(string key);
    }

    /// <summary>Simple in-memory <see cref="IRepository{T}"/> backed by a dictionary.</summary>
    public class Repository<T> : IRepository<T>
    {
        private readonly Dictionary<string, T> _store = new Dictionary<string, T>();

        /// <summary>Count of repository instances created this process.</summary>
        public static int TotalRepositories { get; private set; }

        public Repository()
        {
            TotalRepositories = TotalRepositories + 1;
        }

        public void Add(string key, T item)
        {
            _store[key] = item;
        }

        public T Get(string key)
        {
            if (_store.ContainsKey(key))
            {
                return _store[key];
            }
            return default(T);
        }

        public List<T> All()
        {
            var items = new List<T>();
            foreach (var pair in _store)
            {
                items.Add(pair.Value);
            }
            return items;
        }

        public bool Remove(string key)
        {
            return _store.Remove(key);
        }
    }

    /// <summary>Small collection helpers shared across the service layer.</summary>
    public static class Query
    {
        /// <summary>Return the items for which <paramref name="predicate"/> holds.</summary>
        public static List<T> Where<T>(List<T> items, Func<T, bool> predicate)
        {
            var matched = new List<T>();
            foreach (var item in items)
            {
                if (predicate(item))
                {
                    matched.Add(item);
                }
            }
            return matched;
        }
    }
}
