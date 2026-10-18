const faces = { shrug: '¯\\_(ツ)_/¯', tableflip: '(╯°□°)╯︵ ┻━┻', unflip: '┬─┬ ノ( ゜-゜ノ)', lenny: '( ͡° ͜ʖ ͡°)' };
for (const name in faces) {
  const face = faces[name];
  mentos.commands.add(name, face, (args) => args.length > 0 ? `${args} ${face}` : face);
}

mentos.commands.add('mock', 'sPoNgEbOb CaSe', (args) =>
  args.split('').map((c, i) => i % 2 ? c.toUpperCase() : c.toLowerCase()).join(''));
mentos.commands.add('upper', 'SHOUT IT', (args) => args.toUpperCase());
mentos.commands.add('spaced', 's p a c e d', (args) => args.split('').join(' '));
mentos.commands.add('spoiler', 'Hide text behind a warning', (args) => `⚠️ spoiler ahead\n\n\n\n\n${args}`);

const emoji = {
  ':smile:': '😄', ':joy:': '😂', ':heart:': '❤️', ':fire:': '🔥', ':+1:': '👍', ':thumbsup:': '👍',
  ':clap:': '👏', ':eyes:': '👀', ':tada:': '🎉', ':100:': '💯', ':thinking:': '🤔', ':wave:': '👋',
  ':pray:': '🙏', ':rocket:': '🚀', ':sob:': '😭', ':ok:': '👌', ':coffee:': '☕', ':sparkles:': '✨',
};
mentos.compose.onSend((text) => {
  if (!text.includes(':')) return text;
  let out = text;
  for (const code in emoji) out = out.replaceAll(code, emoji[code]);
  return out;
});
