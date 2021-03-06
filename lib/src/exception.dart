import 'events.dart';
import 'message.dart';

class PhoenixException {
  final PhoenixSocketErrorEvent socketError;
  final PhoenixSocketCloseEvent socketClosed;
  final String channelEvent;

  PhoenixException({
    this.socketClosed,
    this.socketError,
    this.channelEvent,
  });

  Message get message {
    if (socketClosed is PhoenixSocketCloseEvent) {
      return Message(event: PhoenixChannelEvent.error);
    } else if (socketError is PhoenixSocketErrorEvent) {
      return Message(event: PhoenixChannelEvent.error);
    }
    return null;
  }
}
