// Replies at most once per chat per away session, and never to groups.
let replied = {};
const fallback = "I'm away right now and will reply when I'm back.";

mentos.on('message', (msg) => {
  if (!mentos.storage.get('on', false)) return;
  if (!msg.scope.startsWith('dm:') || replied[msg.scope]) return;
  replied[msg.scope] = true;
  mentos.chats.send(msg.scope, `🌙 ${mentos.storage.get('note', fallback)}`);
  mentos.storage.set('count', mentos.storage.get('count', 0) + 1);
  mentos.log(`auto-replied to ${msg.name}`);
});

mentos.ui.page({
  title: 'Away message',
  icon: 'away',
  render: () => [
    {
      type: 'switch',
      label: 'I am away',
      subtitle: 'Each person gets one reply until you come back',
      value: mentos.storage.get('on', false),
      onChange: (v) => {
        mentos.storage.set('on', v);
        replied = {};
        if (!v) mentos.storage.set('count', 0);
        mentos.notify(v ? 'Away message on' : 'Welcome back');
      },
    },
    {
      type: 'input',
      key: 'note',
      label: 'Message',
      multiline: true,
      value: mentos.storage.get('note', fallback),
      onChange: (v) => mentos.storage.set('note', v),
    },
    { type: 'stat', label: 'people answered while away', value: `${mentos.storage.get('count', 0)}` },
  ],
});
