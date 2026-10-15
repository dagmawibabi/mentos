import 'iroh_transport.dart';
import 'transport.dart';

/// Uses the bundled iroh node when `libmentos_net` is present, otherwise
/// stays fully local.
Transport createTransport() => IrohTransport.tryOpen() ?? OfflineTransport();
