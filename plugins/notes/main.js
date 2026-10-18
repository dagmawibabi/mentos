let draft = '';

function notes() { return mentos.storage.get('notes', []); }

function add(text) {
  const list = notes();
  list.unshift({ text: text, at: Date.now() });
  mentos.storage.set('notes', list.slice(0, 200));
}

function ago(ms) {
  const m = Math.floor((Date.now() - ms) / 60000);
  if (m < 1) return 'now';
  if (m < 60) return `${m}m`;
  if (m < 1440) return `${Math.floor(m / 60)}h`;
  return `${Math.floor(m / 1440)}d`;
}

function save() {
  if (draft.trim().length > 0) add(draft.trim());
  draft = '';
}

mentos.commands.add('note', 'Save a line to Quick notes', (args) => {
  if (args.length > 0) { add(args); mentos.notify('Saved to notes'); }
  return '';
});

mentos.ui.page({
  title: 'Quick notes',
  icon: 'note',
  render: () => {
    const list = notes();
    return [
      { type: 'input', key: 'draft', hint: 'Write something…', value: draft, onChange: (v) => { draft = v; }, onSubmit: (v) => { draft = v; save(); } },
      { type: 'row', children: [
        { type: 'button', label: 'Save', onTap: save },
        list.length > 0 ? { type: 'button', label: 'Clear all', style: 'text', onTap: () => mentos.storage.set('notes', []) } : null,
      ] },
      list.length === 0
        ? { type: 'text', text: 'No notes yet. Tip: type /note in any chat.', style: 'muted' }
        : { type: 'list', items: list.map((n, i) => ({
            title: n.text,
            subtitle: 'tap to remove',
            trailing: ago(n.at),
            onTap: () => { const l = notes(); l.splice(i, 1); mentos.storage.set('notes', l); },
          })) },
    ];
  },
});
