package inventory.data;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Simple in-memory {@link Repository} backed by a hash map. */
public class InMemoryRepository<T> implements Repository<T> {
    private final Map<String, T> store = new HashMap<>();

    /** Count of repository instances created this process. */
    public static int totalRepositories = 0;

    public InMemoryRepository() {
        totalRepositories = totalRepositories + 1;
    }

    @Override
    public void add(String key, T item) {
        store.put(key, item);
    }

    @Override
    public T get(String key) {
        return store.get(key);
    }

    @Override
    public List<T> all() {
        return new ArrayList<>(store.values());
    }

    @Override
    public boolean remove(String key) {
        return store.remove(key) != null;
    }
}
