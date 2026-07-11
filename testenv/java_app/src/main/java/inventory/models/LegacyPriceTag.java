package inventory.models;

// intentionally dead (fixture): no code constructs or references LegacyPriceTag.
/** Obsolete price sticker kept only for a migration that never shipped. */
public class LegacyPriceTag {
    private String code;

    public LegacyPriceTag(String code) {
        this.code = code;
    }

    public String render() {
        return "$" + code;
    }
}
