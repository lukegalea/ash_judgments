<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The BPMN bridge

Questions declaring `bpmn_callable? true` get a generated
`judge_<name>_signals` action: it runs the SAME judge path (same state
projection, same profile resolution, same recorder) and returns a
STRING-KEYED, SCALAR-VALUED map — the shape a BPMN `ash:call` may
promote onto a token. **Answer structs never promote** (the struct /
dotted-path promotion hazard is the whole reason this shape exists).

## The signals map

| Signal | Meaning |
|---|---|
| `<q>__judgment_id` | The observation id — the token's join back to the full ledger row |
| `<q>__p` | Noul probability (decimal string) |
| `<q>__value` + `<q>__confidence` | Choice value and confidence |
| `<q>__position` + `<q>__level` | Score position and nearest level |

## The promote snippet

The `ash:call` ref names a callable the HOST declared in a domain's
`callables` block — usually a thin wrapper that adapts the subject's
fields into the projection input and delegates to the generated action.
The engine promotes only the DECLARED signals, and only scalars (the
engine gates this too — a struct cannot pass even if the callee returned
one).

```xml
<!-- The host's callable: wraps the subject field, delegates to the
     generated signals action, returns its scalar map unchanged. -->
<bpmn2:serviceTask id="JudgeSignals" name="Judge the note (signals)">
  <bpmn2:extensionElements>
    <ash:call ref="MyApp.Domain.judge_note_signals"/>
    <ash:inputs>
      <ash:input name="input" from="subject.body"/>
    </ash:inputs>
    <ash:promote>
      <ash:signal name="notes_follow_up__p"/>
      <ash:signal name="notes_follow_up__judgment_id" required="true"/>
    </ash:promote>
  </bpmn2:extensionElements>
</bpmn2:serviceTask>
```

Promoted signals are readable downstream as `routing.<signal>` — a
gateway routes on `routing.band = "admit"`; a later `ash:call` reads
them back as inputs.

The standing-evaluation fixture (`priv/bpmn/standing_evaluation.bpmn`)
walks the whole lane: judged signals → band-table step on the promoted
probability → gateway → human review task → end. The integration test
(`test/bpmn_bridge_test.exs`) drives it through the ash_bpmn
interpreter with the Oban shim inline.

## Actor discipline ([L]4)

The signals action runs as whoever calls it — the requesting actor's
context passes through to the recorder unchanged, and the package
injects NO default actor. Where a process runs unattended, the HOST
wires its own automation principal and `grant_ref` per [L]4; the
package asserts only that it never injects a default.

## No runtime edge

`ash_bpmn` is a DEV/TEST-ONLY optional dependency: the integration test
runs the fixture through the interpreter in test, and `lib/` imports
nothing from ash_bpmn. The dependency DAG (t-core-bridge-placement §0)
allows no runtime edge between ash_bpmn and ash_judgments in either
direction.
