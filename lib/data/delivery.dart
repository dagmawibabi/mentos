enum Delivery {
  queued,
  sending,
  sent,
  delivered,
  read,
  failed,
  cancelled,
  saved,
}

extension DeliveryLabel on Delivery {
  String get label => switch (this) {
    Delivery.queued => 'Waiting to send',
    Delivery.sending => 'Sending',
    Delivery.sent => 'Sent · awaiting confirmation',
    Delivery.delivered => 'Delivered',
    Delivery.read => 'Read',
    Delivery.failed => 'Delivery unconfirmed',
    Delivery.cancelled => 'Retries cancelled',
    Delivery.saved => 'Saved locally',
  };
}

class RecipientDelivery {
  const RecipientDelivery({
    required this.id,
    required this.peer,
    required this.state,
    this.attempts = 0,
    this.nextAt = 0,
    this.error,
  });

  final String id;
  final String peer;
  final Delivery state;
  final int attempts;
  final int nextAt;
  final String? error;

  bool get pending =>
      {Delivery.queued, Delivery.sending, Delivery.sent}.contains(state);
  bool get canRetry => state == Delivery.failed || state == Delivery.cancelled;
  bool get canCancel => pending || state == Delivery.failed;
}

Delivery aggregateDelivery(List<RecipientDelivery> recipients) {
  if (recipients.isEmpty) return Delivery.saved;
  final states = recipients.map((r) => r.state).toSet();
  if (states.contains(Delivery.failed)) return Delivery.failed;
  if (states.contains(Delivery.sending)) return Delivery.sending;
  if (states.contains(Delivery.queued)) return Delivery.queued;
  if (states.contains(Delivery.sent)) return Delivery.sent;
  if (states.contains(Delivery.cancelled)) return Delivery.cancelled;
  if (states.every((s) => s == Delivery.read)) return Delivery.read;
  if (states.contains(Delivery.delivered) || states.contains(Delivery.read)) {
    return Delivery.delivered;
  }
  return Delivery.saved;
}
