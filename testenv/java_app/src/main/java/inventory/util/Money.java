package inventory.util;

/** Small money helpers reused across the app via {@code import static}. */
public final class Money {
    private Money() {
    }

    /** Convert whole cents to whole dollars. */
    public static int dollars(int cents) {
        return cents / 100;
    }

    /** Format a cents amount as a "$D.CC" string. */
    public static String format(int cents) {
        return "$" + dollars(cents) + "." + pad(cents % 100);
    }

    private static String pad(int n) {
        return n < 10 ? "0" + n : Integer.toString(n);
    }
}
