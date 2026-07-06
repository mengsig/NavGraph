// Shared data shapes for the orders client.

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
