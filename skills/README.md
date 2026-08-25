# Skills for the Kineviz Agent

A [skill](https://github.com/Kineviz/graphxr-skills) is a `SKILL.md` the Kineviz
Agent loads on demand, when its description matches what you asked for.

| Skill | What it fixes |
|---|---|
| [`spanner-graph-gql`](spanner-graph-gql/) | The Agent's built-in database knowledge is **KoreDB**, and its system prompt says so unconditionally. Against a Spanner-backed project it will reach for KoreDB Cypher. This teaches it GQL — including the schemaless rules that have no Cypher equivalent. |

## Installing one

Skills are read from `<your project folder>/.agents/skills/`. Copy the whole
directory in:

```bash
mkdir -p "<your project folder>/.agents/skills"
cp -r skills/spanner-graph-gql "<your project folder>/.agents/skills/"
```

In Kineviz Desktop, "your project folder" is the folder the project uses — the
one you picked with **Open folder**, if you did. Restart the agent session (or
start a new chat) and ask it to list its skills; `spanner-graph-gql` should be
there.

You do not need to load it by hand. The Agent reads skill *descriptions* and
loads the body when one is relevant, so asking a GQL question is enough.
