// Talks only to the Nudge plugin on your contacts' devices.
const kinds = ['👋 Hi!', '☕ Coffee?', '📞 Call me', '🔥 Look at this'];
let inbox = mentos.storage.get('inbox', []);

mentos.peers.on((msg) => {
  if (!msg.data || typeof msg.data.text !== 'string') return;
  inbox.unshift({ from: msg.name, text: msg.data.text.slice(0, 80), at: Date.now() });
  inbox = inbox.slice(0, 30);
  mentos.storage.set('inbox', inbox);
  mentos.notify(`${msg.name}: ${msg.data.text}`);
});

function ago(ms) {
  const m = Math.floor((Date.now() - ms) / 60000);
  return m < 1 ? 'now' : m < 60 ? `${m}m` : `${Math.floor(m / 60)}h`;
}

mentos.ui.page({
  title: 'Nudge',
  icon: 'bolt',
  render: () => {
    const people = mentos.peers.list();
    return [
      { type: 'text', text: 'Contacts', style: 'strong' },
      people.length === 0
        ? { type: 'text', text: 'Add contacts to nudge them.', style: 'muted' }
        : { type: 'column', children: people.map(p => ({ type: 'card', children: [
            { type: 'text', text: `${p.name}${p.online ? ' · online' : ''}`, style: 'strong' },
            { type: 'row', children: kinds.map(k => ({
              type: 'button', label: k, style: 'outline',
              onTap: () => { mentos.peers.send(p.id, { text: k }); mentos.notify(`Sent to ${p.name}`); },
            })) },
          ] })) },
      { type: 'divider' },
      { type: 'text', text: 'Received', style: 'strong' },
      inbox.length === 0
        ? { type: 'text', text: 'No nudges yet.', style: 'muted' }
        : { type: 'list', items: inbox.map(n => ({ title: n.text, subtitle: n.from, trailing: ago(n.at) })) },
    ];
  },
});
mentos.ui.tab({ title: 'Nudge', icon: 'bolt', page: 'main' });
