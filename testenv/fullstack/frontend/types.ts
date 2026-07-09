// Shared data shapes for the API clients.

export interface Order {
  id: number;
  sku: string;
  quantity: number;
  status: "pending" | "shipped" | "cancelled";
}

export interface NewOrder {
  sku: string;
  quantity: number;
}

export interface Customer {
  id: number;
  name: string;
  email: string;
  tier: "standard" | "gold" | "platinum";
}

export interface NewCustomer {
  name: string;
  email: string;
  tier?: Customer["tier"];
}

export interface InventoryItem {
  sku: string;
  name: string;
  on_hand: number;
  reorder_at: number;
}

export interface NewItem {
  sku: string;
  name: string;
  on_hand: number;
  reorder_at?: number;
}

// Payload carried over the message bus for order lifecycle events.
export interface OrderEvent {
  order_id: number;
  detail?: Record<string, unknown>;
}

// intentionally dead (fixture): no client imports or uses LegacyInvoice.
export interface LegacyInvoice {
  number: string;
  paid: boolean;
}
