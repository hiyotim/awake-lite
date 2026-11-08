// AwakeLite OpenCode read-only connector — marker "{marker}".
// Family "{family}", target "{target}", generation "{generation}".
// Reads the existing local service; never restarts it. Helper: "{helperPath}".
// Inert template: the connector runs in the app, this file starts nothing.
// It performs no request, starts no timer or thread, and captures no transcript.
// Session presence alone is not work; the app reads execution detail instead.

export const awakeLite = {
  marker: "{marker}",
  family: "{family}",
  target: "{target}",
  generation: "{generation}",
  helperPath: "{helperPath}",
};

export default awakeLite;
