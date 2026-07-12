package inventory.data;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;

/** Small collection helpers shared across the service layer. */
public final class Query {
    private Query() {
    }

    /** Return the items for which {@code predicate} holds. */
    public static <T> List<T> where(List<T> items, Predicate<T> predicate) {
        List<T> matched = new ArrayList<>();
        for (T item : items) {
            if (predicate.test(item)) {
                matched.add(item);
            }
        }
        return matched;
    }
}
