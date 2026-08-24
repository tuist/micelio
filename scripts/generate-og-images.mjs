#!/usr/bin/env node

/**
 * Render one social-preview image for every Zola content page.
 *
 * The cards deliberately use the site's own terse, monospace presentation
 * rather than a separate illustration system. They are derived artefacts:
 * static/og is cleared and rebuilt before Zola copies static assets to public.
 */

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contentDirectory = join(root, "content");
const outputDirectory = join(root, "static", "og");
const temporaryDirectory = join(
  tmpdir(),
  "micelio-og-" + process.pid + "-" + Math.random().toString(16).slice(2)
);
const defaultDescription = "Headless & scalable Git forge backed by a write-ahead log in object storage.";

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

async function main() {
  const chrome = chromeExecutable();
  const pages = contentFiles(contentDirectory)
    .map(pageFromFile)
    .sort((left, right) => left.route.localeCompare(right.route));

  rmSync(outputDirectory, { recursive: true, force: true });
  mkdirSync(outputDirectory, { recursive: true });
  mkdirSync(temporaryDirectory, { recursive: true });

  try {
    for (const page of pages) {
      const output = join(outputDirectory, ...page.destination);
      mkdirSync(dirname(output), { recursive: true });

      const source = join(temporaryDirectory, page.destination.join("-") + ".html");
      writeFileSync(source, documentFor(page));

      await takeScreenshot(
        chrome,
        [
          "--headless=new",
          "--disable-gpu",
          "--disable-dev-shm-usage",
          "--disable-background-networking",
          "--disable-component-update",
          "--disable-sync",
          "--disable-features=MediaRouter,OptimizationHints,Translate",
          "--force-color-profile=srgb",
          "--hide-scrollbars",
          "--metrics-recording-only",
          "--no-default-browser-check",
          "--no-first-run",
          "--run-all-compositor-stages-before-draw",
          "--virtual-time-budget=100",
          "--window-size=1200,630",
          "--user-data-dir=" + join(temporaryDirectory, "chrome-" + page.destination.join("-")),
          "--screenshot=" + output,
          "file://" + source
        ],
        output
      );
    }
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }

  console.log("Generated " + pages.length + " social-preview images in static/og.");
}

async function takeScreenshot(chrome, arguments_, output) {
  const child = spawn(chrome, arguments_, { stdio: "ignore" });

  await new Promise((resolve, reject) => {
    let settled = false;

    const succeed = () => {
      if (settled) {
        return;
      }

      settled = true;
      clearInterval(interval);
      clearTimeout(timeout);
      resolve();
    };

    const fail = (error) => {
      if (settled) {
        return;
      }

      settled = true;
      clearInterval(interval);
      clearTimeout(timeout);
      reject(error);
    };

    const interval = setInterval(() => {
      if (existsSync(output)) {
        succeed();
      }
    }, 25);

    const timeout = setTimeout(() => {
      child.kill();
      fail(new Error("Timed out while rendering " + output + "."));
    }, 15_000);

    child.once("error", (error) => {
      fail(error);
    });

    child.once("exit", (code) => {
      if (existsSync(output)) {
        succeed();
      } else {
        fail(new Error("Headless Chrome exited with status " + code + " before rendering " + output + "."));
      }
    });
  });

  if (child.exitCode === null) {
    child.kill();
    await new Promise((resolve) => child.once("exit", resolve));
  }
}

function contentFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);

    if (entry.isDirectory()) {
      return contentFiles(path);
    }

    return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
  });
}

function pageFromFile(path) {
  const { frontMatter, body } = splitFrontMatter(readFileSync(path, "utf8"));
  const title = frontMatter.title ?? firstHeading(body) ?? titleFromFilename(path);
  const description = firstParagraph(body) ?? defaultDescription;
  const route = routeFor(path);

  return {
    title,
    description,
    route,
    destination: destinationFor(route)
  };
}

function splitFrontMatter(source) {
  if (!source.startsWith("+++\n")) {
    return { frontMatter: {}, body: source };
  }

  const end = source.indexOf("\n+++", 4);

  if (end === -1) {
    throw new Error("Unclosed Zola front matter.");
  }

  const frontMatter = source.slice(4, end);
  const body = source.slice(end + 4).replace(/^\n/, "");
  const title = frontMatter.match(/^title\s*=\s*"([^"]+)"/m)?.[1];

  return { frontMatter: title ? { title } : {}, body };
}

function firstHeading(markdown) {
  return markdown.match(/^#\s+(.+)$/m)?.[1]?.trim();
}

function firstParagraph(markdown) {
  const paragraph = markdown
    .replace(/^#.+$/gm, "")
    .split(/\n\s*\n/)
    .map((value) => value.trim())
    .find((value) => value && !value.startsWith(String.fromCharCode(96).repeat(3)) && !value.startsWith("<"));

  return paragraph ? plainText(paragraph) : null;
}

function plainText(value) {
  return value
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[\x60*_>#]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function titleFromFilename(path) {
  const name = basename(path, ".md");
  return name === "_index" ? "Micelio" : name.replaceAll("-", " ");
}

function routeFor(path) {
  const parts = relative(contentDirectory, path).split(sep);
  const file = parts.pop();
  const stem = basename(file, ".md");

  if (stem !== "_index") {
    parts.push(stem);
  }

  return parts.length === 0 ? "/" : "/" + parts.join("/") + "/";
}

function destinationFor(route) {
  return route === "/" ? ["index.png"] : [...route.split("/").filter(Boolean), "index.png"];
}

function documentFor({ title, description, route }) {
  const eyebrow =
    route === "/" ? "HEADLESS & SCALABLE GIT FORGE" : "MICELIO // " + route.slice(1, -1).toUpperCase();

  return (
    "<!doctype html>" +
    '<html lang="en">' +
    "<head>" +
    '<meta charset="utf-8">' +
    "<style>" +
    "* { box-sizing: border-box; }" +
    "html, body { width: 1200px; height: 630px; margin: 0; }" +
    "body { background: #ffffff; color: #171717; font-family: ui-monospace, 'SF Mono', 'Cascadia Mono', 'Roboto Mono', Menlo, Consolas, monospace; }" +
    "main { display: flex; flex-direction: column; width: 100%; height: 100%; padding: 58px 68px 52px; }" +
    "header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #171717; padding-bottom: 23px; }" +
    ".wordmark { font-size: 20px; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; }" +
    ".eyebrow { color: #525252; font-size: 15px; letter-spacing: 0.08em; text-transform: uppercase; }" +
    "section { display: flex; flex: 1; flex-direction: column; justify-content: center; max-width: 960px; }" +
    "h1 { max-width: 940px; margin: 0; font-size: 64px; font-weight: 700; letter-spacing: -0.055em; line-height: 1.02; }" +
    "p { max-width: 830px; margin: 31px 0 0; color: #404040; font-size: 24px; line-height: 1.45; }" +
    "footer { color: #737373; font-size: 16px; }" +
    "</style>" +
    "</head>" +
    "<body>" +
    "<main>" +
    "<header><div class='wordmark'>micelio</div><div class='eyebrow'>" +
    escapeHtml(eyebrow) +
    "</div></header>" +
    "<section><h1>" +
    escapeHtml(title) +
    "</h1><p>" +
    escapeHtml(truncate(description, 190)) +
    "</p></section>" +
    "<footer>micelio.dev</footer>" +
    "</main>" +
    "</body>" +
    "</html>"
  );
}

function truncate(value, length) {
  return value.length <= length ? value : value.slice(0, length - 1).trimEnd() + "…";
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[character];
  });
}

function chromeExecutable() {
  const configured = [process.env.CHROME_BIN, process.env.GOOGLE_CHROME_BIN].find(Boolean);

  if (configured) {
    return configured;
  }

  if (process.platform === "darwin") {
    const macOsChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

    if (existsSync(macOsChrome)) {
      return macOsChrome;
    }
  }

  return "google-chrome";
}
