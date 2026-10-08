/**
 * Review tools for pi-review.sh: the reviewer reports through tool calls, not
 * a JSON blob at the end of its reply.
 *
 * Each call is checked as it is made - severity, an in-scope file, a positive
 * integer line, a reopen id that exists - and a bad call comes back to the model
 * as an error it can correct, so one malformed finding no longer sinks the
 * report. finish_review is the "reported" sentinel: a run that ends without it
 * did not report, however much it said.
 *
 * Reads  $PI_REVIEW_DIR/scope.json (in-scope files) and prior-comments.txt.
 * Writes $PI_REVIEW_OUT/findings.jsonl, reopens.jsonl, done.
 */

import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { StringEnum, Type } from "@mariozechner/pi-ai";
import { defineTool, type ExtensionAPI } from "@mariozechner/pi-coding-agent";

const REVIEW = process.env.PI_REVIEW_DIR ?? "/review";
const OUT = process.env.PI_REVIEW_OUT ?? "/out";

const scope = (): string[] => JSON.parse(readFileSync(join(REVIEW, "scope.json"), "utf8"));
const lines = (f: string): string[] =>
	existsSync(join(OUT, f)) ? readFileSync(join(OUT, f), "utf8").split("\n").filter(Boolean) : [];
const text = (t: string) => ({ content: [{ type: "text" as const, text: t }], details: {} });

// Agents written for Claude often grade critical/high/medium/low.
const SEVERITY: Record<string, string> = {
	P0: "P1", P1: "P1", P2: "P2", P3: "P3", CRITICAL: "P1", HIGH: "P2", MEDIUM: "P3", LOW: "P3",
};

const reportFinding = defineTool({
	name: "report_finding",
	label: "Report finding",
	description:
		"Record one review finding. Call it once per finding, as soon as the finding is checked. " +
		"An error result means the finding was NOT recorded: fix the arguments and call again.",
	parameters: Type.Object({
		severity: StringEnum(["P1", "P2", "P3"] as const, {
			description: "P1 critical, P2 important, P3 minor (critical->P1, high->P2, medium/low->P3)",
		}),
		file: Type.String({ description: "Repository-relative path, exactly as in your scope list" }),
		line: Type.Integer({ minimum: 1, description: "Line number in the NEW version of the file, inside a diff hunk" }),
		title: Type.String({ minLength: 1, description: "One-line summary" }),
		body: Type.String({
			minLength: 1,
			description: "The issue, the fix, and its proof - or start with 'judgement:' / 'hypothesis:'",
		}),
	}),
	prepareArguments(args: any) {
		if (args && typeof args.severity === "string") {
			args.severity = SEVERITY[args.severity.trim().toUpperCase()] ?? args.severity;
		}
		if (args && typeof args.line === "string" && /^\d+$/.test(args.line.trim())) args.line = Number(args.line);
		return args;
	},
	async execute(_id, p) {
		if (existsSync(join(OUT, "done"))) throw new Error("finish_review was already called; the report is closed.");
		const files = scope();
		if (!files.includes(p.file)) {
			throw new Error(`'${p.file}' is not in your scope. In-scope files:\n${files.join("\n")}`);
		}
		appendFileSync(join(OUT, "findings.jsonl"), JSON.stringify(p) + "\n");
		return text(`Recorded finding #${lines("findings.jsonl").length}: ${p.severity} ${p.file}:${p.line}`);
	},
});

const reopenThread = defineTool({
	name: "reopen_thread",
	label: "Reopen thread",
	description:
		"Reopen one of YOUR earlier comments whose reply was unreasonable (dismissive, incorrect, or ignored the issue). " +
		"Never reopen a reasoned decline on wording or style grounds.",
	parameters: Type.Object({
		comment_id: Type.Integer({ description: "The Thread ID from prior-comments.txt" }),
		reason: Type.String({ minLength: 1, description: "Why the reply is insufficient" }),
	}),
	prepareArguments(args: any) {
		if (args && typeof args.comment_id === "string" && /^\d+$/.test(args.comment_id.trim())) {
			args.comment_id = Number(args.comment_id);
		}
		return args;
	},
	async execute(_id, p) {
		if (existsSync(join(OUT, "done"))) throw new Error("finish_review was already called; the report is closed.");
		const prior = readFileSync(join(REVIEW, "prior-comments.txt"), "utf8");
		if (!prior.includes(`Thread (ID: ${p.comment_id})`)) {
			throw new Error(`No thread with ID ${p.comment_id} in prior-comments.txt; use an ID listed there.`);
		}
		appendFileSync(join(OUT, "reopens.jsonl"), JSON.stringify(p) + "\n");
		return text(`Reopen recorded for thread ${p.comment_id}`);
	},
});

const finishReview = defineTool({
	name: "finish_review",
	label: "Finish review",
	description:
		"Close your review. Call exactly once, after every finding has been recorded with report_finding - " +
		"also when there is nothing to report. Without this call your review counts as not delivered.",
	parameters: Type.Object({}),
	async execute() {
		const n = lines("findings.jsonl").length, r = lines("reopens.jsonl").length;
		writeFileSync(join(OUT, "done"), `${n} ${r}\n`);
		return text(`Review delivered: ${n} finding(s), ${r} reopen(s). You are done - stop now.`);
	},
});

export default function (pi: ExtensionAPI) {
	pi.registerTool(reportFinding);
	pi.registerTool(reopenThread);
	pi.registerTool(finishReview);
}
