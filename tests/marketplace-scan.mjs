// Runs the Omarchy plugin marketplace's Automated Security Baseline on this
// checkout, the same static scan a submission gets. Usage:
//   node tests/marketplace-scan.mjs <marketplace-checkout> <plugin-repo>
// Exit 0: passed or review-required without findings. Exit 1: findings or a
// scan the marketplace would treat as failed.
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const all = process.argv.includes("--all");
const skipped = new Set([".github", "coverage", "docs", "fixtures", "node_modules", "spec", "specs", "test", "tests"]);
const [market, repo] = process.argv.slice(2).filter((a) => a !== "--all").map((p) => resolve(p));
const { buildSecurityBaseline } = await import(
  pathToFileURL(join(market, "scripts/security-baseline-analysis.mjs")).href
);
const slug = JSON.parse(readFileSync(join(repo, "manifest.json"), "utf8")).repository
  .replace("https://github.com/", "");
const files = execFileSync("git", ["-C", repo, "ls-files"], { encoding: "utf8" })
  .trim().split("\n")
  .filter((path) => !/\.(png|jpe?g|webp|avif)$/i.test(path))
  // The marketplace does not treat these folders as runtime source. Pass
  // --all to scan them as well.
  .filter((path) => all || !path.split("/").slice(0, -1).some((part) => skipped.has(part)))
  .map((path) => ({
    path,
    content: readFileSync(join(repo, path), "utf8"),
    mode: statSync(join(repo, path)).mode & 0o111 ? "100755" : "100644",
  }));

let result;
try {
  result = buildSecurityBaseline({
    repository: slug,
    repoUrl: `https://github.com/${slug}`,
    commitSha: "0".repeat(40),
    files,
  });
} catch (error) {
  console.log(`  [FAIL] the scan itself failed (the marketplace fails closed): ${error.code} ${error.message}`);
  process.exit(1);
}
console.log(`  outcome: ${result.outcome}`);
for (const c of result.capabilities) console.log(`  needs maintainer review: ${c.id}`);
for (const f of result.findings) {
  console.log(`  [FAIL] finding ${f.ruleId}: ${f.title}`);
  for (const e of f.evidence ?? []) console.log(`         ${e.path}:${e.line}  ${e.snippet}`);
}
process.exit(result.findings.length ? 1 : 0);
