# Read Mode — design spec

*Status: implemented (v1). Tracking: [#46](https://github.com/rayl15/OpenVision/issues/46).*

## Summary
Point the glasses at text — a sign, label, menu, receipt, mail, screen — and hear it read aloud, or ask a question about it ("what's the total?", "when does this expire?"). Audio-first, hands-free, and it works **offline**: the reading happens on-device.

This is the first feature of an accessibility-first direction for OpenVision: the **offline, private, open AI "eyes"** for the mainstream glasses people already own — filling the gap left by volunteer-only (Be My Eyes on glasses) and cloud-only (Seeing AI, Be My AI) assistants.

## Why this design (research-grounded)
On-device VLM accessibility research converges on one problem: **models confidently invent details a blind/low-vision user can't verify.** So the architecture puts a deterministic component in charge of *seeing*:

- **Apple Vision OCR does the reading.** It runs on-device, is deterministic, and cannot hallucinate. The assistant reads back what is *actually* there.
- **The LLM only reasons over already-extracted text** (never the raw image) when the user asks a question — so it can't fabricate visual details; worst case it mis-extracts from real text.
- **Abstain, don't guess.** When there's no clear text, say so and suggest repositioning — never invent. ([Long-Form Answers to VQA from BLV](https://arxiv.org/abs/2408.06303) finds most VLMs fail to abstain, and that false info is especially harmful here.)
- **Direct answer first, detail second.** BLV users prefer detailed answers overall, but want the direct answer up front for specific questions.
- **Mention image quality only when it explains a failure** — no nagging "blurry" on usable frames.
- Question patterns informed by [VizWiz](https://arxiv.org/abs/1802.08218) (31k real blind-user visual questions; text-reading dominates).

## Behavior
1. **Trigger** — "read this / read the menu / read it / what does this say", a leading "read …", or a specific question about visible text.
2. **Capture** one frame from the glasses (click-and-go: start stream if needed, grab a fresh frame, stop).
3. **OCR** on-device — Apple Vision `VNRecognizeTextRequest`, `.accurate`, automatic language detection + correction, lines returned in reading order with confidence.
4. **Respond**
   - *Bare read request* → read the recognized text aloud.
   - *Specific question* → answer via the active backend using **only** the OCR text (grounded + abstention prompt).
5. **Abstain** when no clear text: guidance tailored by a cheap sharpness check — "hold steady" if blurry, otherwise "move closer / adjust the angle." Never fabricate.

## Components
| File | Role |
|---|---|
| `Services/Vision/TextReaderService.swift` | On-device OCR (ordered lines + confidence), Laplacian-variance sharpness score, and the grounded/abstention prompt |
| `Views/VoiceAgent/VoiceAgentView.swift` | `isReadCommand` / `readIsSpecificQuestion` routing + `handleReadText` (capture → OCR → read/answer) |

Backend-agnostic — OCR is local, so Read Mode works on every backend (Local MLX, OpenAI, Gemini Live, OpenClaw, Apple Intelligence). The question path sends a text-only grounded prompt through the existing `sendPromptToActiveBackend`.

## Not in v1 (follow-ups)
- Currency / color / barcode-product identification (Apple Vision barcode is also on-device).
- "Summarize this" for long documents.
- Language of *output* vs. detected language (read/translate).
- A dedicated Accessibility settings section (verbosity, auto-repeat on blur).
- Episodic memory ("where did I leave my keys?") — the [Ego4D](https://github.com/EGO4D/episodic-memory) frontier; separate, heavier effort.
