package inventory.data;

import java.util.List;

/** Generic key/value store contract used by the service layer. */
public interface Repository<T> {
    /** Insert or replace the item stored under {@code key}. */
    void add(String key, T item);

    /** Fetch the item for {@code key}, or null when absent. */
    T get(String key);

    /** Enumerate every stored item. */
    List<T> all();

    /** Remove the item under {@code key}; true when present. */
    boolean remove(String key);
}
