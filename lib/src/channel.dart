import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';

import 'events.dart';
import 'exception.dart';
import 'message.dart';
import 'push.dart';
import 'socket.dart';

/// The different states a channel can be.
enum PhoenixChannelState {
  /// The channel is closed, after a normal leave.
  closed,

  /// The channel is errored.
  errored,

  /// The channel is joined and functional.
  joined,

  /// The channel is waiting for a reply to its 'join'
  /// request.
  joining,

  /// The channel is waiting for a reply to its 'leave'
  /// request.
  leaving,
}

/// Bi-directional and isolated communication channel shared between
/// differents clients through a common Phoenix server.
class PhoenixChannel {
  final Map<String, String> _parameters;
  final PhoenixSocket _socket;
  final StreamController<Message> _controller;
  final Map<PhoenixChannelEvent, Completer<Message>> _waiters;
  final List<StreamSubscription> _subscriptions = [];

  /// The name of the topic to which this channel will bind.
  final String topic;

  Duration _timeout;
  PhoenixChannelState _state = PhoenixChannelState.closed;
  Timer _rejoinTimer;
  bool _joinedOnce = false;
  String _reference;
  Push _joinPush;
  Logger _logger;
  Zone _zone;

  /// A list of push to be sent out once the channel is joined.
  final List<Push> pushBuffer = [];

  PhoenixChannel.fromSocket(
    this._socket, {
    this.topic,
    Map<String, String> parameters,
    Duration timeout,
    Zone zone,
  })  : _parameters = parameters ?? {},
        _controller = StreamController.broadcast(),
        _waiters = {},
        _zone = zone.fork(),
        _timeout = timeout ?? _socket.defaultTimeout {
    _joinPush = _prepareJoin();
    _logger = Logger('phoenix_socket.channel.$loggerName');
    _subscriptions.add(messages.listen(_zone.bindUnaryCallback(_onMessage)));
    _subscriptions.addAll(_subscribeToSocketStreams(_socket));
  }

  Duration get timeout => _timeout;
  Map<String, String> get parameters => _parameters;
  Stream<Message> get messages => _controller.stream;
  String get joinRef => _joinPush.ref;
  PhoenixSocket get socket => _socket;
  PhoenixChannelState get state => _state;

  bool get isClosed => _state == PhoenixChannelState.closed;
  bool get isErrored => _state == PhoenixChannelState.errored;
  bool get isJoined => _state == PhoenixChannelState.joined;
  bool get isJoining => _state == PhoenixChannelState.joining;
  bool get isLeaving => _state == PhoenixChannelState.leaving;

  bool get canPush => socket.isConnected && isJoined;

  String _loggerName;
  String get loggerName => _loggerName ??= topic.replaceAll(
      RegExp(
        '[:,*&?!@#\$%]',
      ),
      '_');

  String get reference {
    _reference ??= _socket.nextRef;
    return _reference;
  }

  Future<Message> onPushReply(PhoenixChannelEvent replyEvent) {
    return _zone.run(() {
      if (_waiters.containsKey(replyEvent)) {
        _logger.finer(
          () => 'Removing previous waiter for $replyEvent',
        );
        _waiters.remove(replyEvent);
      }
      _logger.finer(
        () => 'Hooking on channel $topic for reply to $replyEvent',
      );
      final completer = Completer<Message>();
      _waiters[replyEvent] = completer;
      completer.future.whenComplete(() => _waiters.remove(replyEvent));
      return completer.future;
    });
  }

  void close() {
    _zone.run(() {
      if (_state == PhoenixChannelState.closed) {
        return;
      }
      _state = PhoenixChannelState.closed;

      for (final push in pushBuffer) {
        push.cancelTimeout();
      }
      for (final sub in _subscriptions) {
        sub.cancel();
      }

      _joinPush?.cancelTimeout();

      _controller.close();
      _waiters.clear();
      _socket.removeChannel(this);
    });
  }

  void trigger(Message message) {
    _zone.run(() {
      if (!_controller.isClosed) {
        _controller.add(message);
      }
    });
  }

  void triggerError(PhoenixException error) {
    _zone.run(() {
      _logger.fine('Receiving error on channel', error);
      if (!(isErrored || isLeaving || isClosed)) {
        trigger(error.message);
        _logger.warning('Got error on channel', error);
        for (final waiter in _waiters.values) {
          waiter.completeError(error);
        }
        _waiters.clear();
        _state = PhoenixChannelState.errored;
        if (isJoining) {
          _joinPush.reset();
        }
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      }
    });
  }

  Push leave({Duration timeout}) {
    return _zone.run(() {
      _joinPush?.cancelTimeout();
      _rejoinTimer?.cancel();

      _state = PhoenixChannelState.leaving;

      final leavePush = Push(
        this,
        event: PhoenixChannelEvent.leave,
        payload: () => {},
        timeout: timeout,
      );

      var __onClose = _zone.bindUnaryCallback(_onClose);
      leavePush..onReply('ok', __onClose)..onReply('timeout', __onClose);

      if (!socket.isConnected || !isJoined) {
        leavePush.trigger(PushResponse(status: 'ok'));
      } else {
        leavePush.send().then((value) => close());
      }

      return leavePush;
    });
  }

  Push join([Duration newTimeout]) {
    assert(!_joinedOnce);
    return _zone.run(() {
      if (newTimeout is Duration) {
        _timeout = newTimeout;
      }

      _joinedOnce = true;
      _attemptJoin();

      return _joinPush;
    });
  }

  Push push(
    String eventName,
    Map<String, dynamic> payload, [
    Duration newTimeout,
  ]) =>
      pushEvent(
        PhoenixChannelEvent.custom(eventName),
        payload,
        newTimeout,
      );

  Push pushEvent(
    PhoenixChannelEvent event,
    Map<String, dynamic> payload, [
    Duration newTimeout,
  ]) {
    return _zone.run(() {
      assert(_joinedOnce);

      final pushEvent = Push(
        this,
        event: event,
        payload: () => payload,
        timeout: newTimeout ?? timeout,
      );

      if (canPush) {
        pushEvent.send();
      } else {
        pushBuffer.add(pushEvent);
      }

      return pushEvent;
    });
  }

  List<StreamSubscription> _subscribeToSocketStreams(PhoenixSocket socket) {
    return [
      socket.streamForTopic(topic).where(_isMember).listen(_controller.add),
      socket.errorStream.listen(
        _zone.bindUnaryCallback<Null, dynamic>(
          (error) => _rejoinTimer?.cancel(),
        ),
      ),
      socket.openStream.listen(
        _zone.bindUnaryCallback<Null, PhoenixSocketOpenEvent>(
          (event) {
            _rejoinTimer?.cancel();
            if (isErrored) {
              _attemptJoin();
            }
          },
        ),
      )
    ];
  }

  Push _prepareJoin([Duration providedTimeout]) {
    final push = Push(
      this,
      event: PhoenixChannelEvent.join,
      payload: () => parameters,
      timeout: providedTimeout ?? timeout,
    );
    _bindJoinPush(push);
    return push;
  }

  void _bindJoinPush(Push push) {
    _zone.run(() {
      push.clearWaiters();
      push
        ..onReply('ok', _zone.bindUnaryCallback((response) {
          _logger.finer("Join message was ok'ed");
          _state = PhoenixChannelState.joined;
          _rejoinTimer?.cancel();
          for (final push in pushBuffer) {
            push.send();
          }
          pushBuffer.clear();
        }))
        ..onReply('error', _zone.bindUnaryCallback((response) {
          _logger.warning('Join message got error response', response);
          _state = PhoenixChannelState.errored;
          if (socket.isConnected) {
            _startRejoinTimer();
          }
        }))
        ..onReply('timeout', _zone.bindUnaryCallback((response) {
          _logger.warning('Join message timed out');
          final leavePush = Push(
            this,
            event: PhoenixChannelEvent.leave,
            payload: () => {},
            timeout: timeout,
          );
          leavePush.send();
          _state = PhoenixChannelState.errored;
          _joinPush.reset();
          if (socket.isConnected) {
            _startRejoinTimer();
          }
        }));
    });
  }

  void _startRejoinTimer() {
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(timeout, () {
      if (socket.isConnected) _attemptJoin();
    });
  }

  void _attemptJoin() {
    if (!isLeaving) {
      _state = PhoenixChannelState.joining;
      _bindJoinPush(_joinPush);
      unawaited(_joinPush.resend(timeout));
    }
  }

  bool _isMember(Message message) {
    if (message.joinRef != null &&
        message.joinRef != _joinPush.ref &&
        PhoenixChannelEvent.statuses.contains(message.event)) {
      return false;
    }
    return true;
  }

  void _onMessage(Message message) {
    if (message.event == PhoenixChannelEvent.close) {
      _logger.finer('Closing channel $topic');
      _rejoinTimer?.cancel();
      close();
    } else if (message.event == PhoenixChannelEvent.error) {
      _logger.finer('Erroring channel $topic');
      if (isJoining) {
        _joinPush.reset();
      }
      _state = PhoenixChannelState.errored;
      if (socket.isConnected) {
        _rejoinTimer?.cancel();
        _startRejoinTimer();
      }
    } else if (message.event == PhoenixChannelEvent.reply) {
      _controller.add(message.asReplyEvent());
    }

    if (_waiters.containsKey(message.event)) {
      _logger.finer(
        () => 'Notifying waiter for ${message.event}',
      );
      _waiters[message.event].complete(message);
    } else {
      _logger.finer(() => 'No waiter to notify for ${message.event}');
    }
  }

  void _onClose(PushResponse response) {
    _logger.finer('Leave message has completed');
    trigger(Message(
      event: PhoenixChannelEvent.close,
      payload: {'ok': 'leave'},
    ));
  }
}
