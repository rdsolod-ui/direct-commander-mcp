#!/usr/bin/env node
"use strict";

const path = require("node:path");
const { parseArgs } = require("node:util");

const help = `direct-commander <команда> [параметры]

  status                  Версия Коммандера и открытые окна
  panels                  Панели, вкладки и быстрые фильтры
  campaigns               Названия и статусы видимых кампаний
  grid                    Видимая таблица текущей вкладки
  tab <id>                Выбрать вкладку по ID из panels
  filter <текст>          Установить быстрый фильтр
  filter --clear          Очистить быстрый фильтр

  --window <id>           Выбрать окно по ID из status
  --panel main|sub        Левая или правая панель (по умолчанию sub)
  --column <заголовок>    Для grid, можно повторять
  --status <статус>       Для campaigns, точный текст статуса
  --offset <0…10000>      Пропустить строки в видимой области
  --limit <0…50>          Число строк за один вызов, по умолчанию 50
  --json                  Вывод JSON для скриптов
  --help, -h              Справка

direct-commander campaigns --json
direct-commander grid --column "Название" --column "Статус"
direct-commander panels
`;

const flags = {
  json: { type: "boolean" },
  help: { type: "boolean", short: "h" },
  window: { type: "string" },
  panel: { type: "string" },
  column: { type: "string", multiple: true },
  status: { type: "string" },
  offset: { type: "string" },
  limit: { type: "string" },
  clear: { type: "boolean" },
};
const allowed = {
  status: [], panels: ["window"], campaigns: ["window", "panel", "offset", "limit", "status"],
  grid: ["window", "panel", "offset", "limit", "column"],
  tab: ["window", "panel"], filter: ["window", "panel", "clear"],
};

function parse(argv) {
  const { values, positionals } = parseArgs({ args: argv, options: flags, allowPositionals: true });
  const [command, ...args] = positionals;
  if (!argv.length || values.help || command === "help") return { help: true };
  if (!Object.hasOwn(allowed, command)) throw Error("Укажите команду из direct-commander --help.");
  for (const key of Object.keys(values)) {
    if (key !== "json" && !allowed[command].includes(key)) throw Error(`Команда ${command} не принимает --${key}.`);
  }
  const wantsArg = command === "tab" || (command === "filter" && !values.clear);
  if (args.length !== Number(wantsArg)) throw Error(`Проверьте аргументы команды ${command}. См. --help.`);
  if (values.window !== undefined && !/^\d+-\d+-\d+$/.test(values.window)) throw Error("Возьмите ID окна из status.");
  if (values.panel !== undefined && !["main", "sub"].includes(values.panel)) throw Error("--panel принимает main или sub.");
  for (const [key, max] of [["offset", 10000], ["limit", 50]]) {
    if (values[key] === undefined) continue;
    if (!/^\d+$/.test(values[key]) || Number(values[key]) > max) throw Error(`--${key} принимает целое число от 0 до ${max}.`);
    values[key] = Number(values[key]);
  }
  if (values.status !== undefined && !values.status.trim()) throw Error("Укажите непустой статус.");
  if (values.column && (values.column.length > 16 || values.column.some(v => !v.trim() || v.trim().length > 128))) {
    throw Error("Укажите до 16 непустых заголовков, каждый длиной до 128 символов.");
  }
  return { command, arg: args[0], values };
}

async function execute(call, { command, arg, values }) {
  const status = await call("status");
  if (command === "status") return status;
  if (!status.windows.length) throw Error("Откройте Директ Коммандер в текущем сеансе Windows.");
  if (!values.window && status.windows.length > 1) throw Error("Открыто несколько окон. Выберите --window <id> из status.");
  const win = values.window ? status.windows.find(w => w.id === values.window) : status.windows[0];
  if (!win) throw Error("Окно закрылось или изменилось. Обновите ID через status.");
  const snapshot = await call("list_panels", { window_id: win.id });
  if (command === "panels") return snapshot;
  const panel = snapshot.panels.find(p => p.panel === (values.panel ?? "sub"));
  if (!panel?.selected_tab) throw Error("Не удалось определить выбранную вкладку. Проверьте panels.");
  const view = { window_id: win.id, panel: panel.panel, expected_tab: panel.selected_tab };
  if (command === "tab") return call("select_tab", { ...view, target_tab: arg });
  if (command === "filter") {
    if (typeof panel.quick_filter !== "string") throw Error("У этой панели нет доступного быстрого фильтра.");
    return call("set_quick_filter", { ...view, expected_text: panel.quick_filter, text: values.clear ? "" : arg });
  }
  if (command === "campaigns" && panel.selected_tab !== "campaigns") {
    throw Error(`В панели ${panel.panel} открыта вкладка ${panel.selected_tab}. Выберите «Кампании» или другую панель через --panel.`);
  }
  const page = { ...view, offset: values.offset ?? 0, limit: values.limit ?? 50 };
  const columns = command === "campaigns" ? ["Название", "Статус"] : values.column;
  if (!columns) return call("read_grid", page);
  const data = await call("read_columns", { ...page, columns });
  if (data.scroll_before.horizontal !== data.scroll_after.horizontal || data.scroll_before.vertical !== data.scroll_after.vertical) {
    throw Error("Коммандер не подтвердил восстановление прокрутки.");
  }
  if (values.status === undefined) return data;
  const expected = values.status.trim().toLocaleLowerCase("ru");
  return { ...data, status_filter: values.status, rows: data.rows.filter(r => r.values[1]?.trim().toLocaleLowerCase("ru") === expected) };
}

// Keep the tab-separated output readable even when a UI cell contains control characters.
function line(cells) {
  console.log(cells.map(v => v == null ? "—" : String(v).replace(/[\x00-\x1f\x7f-\x9f]/g, " ")).join("\t"));
}

function render(command, data) {
  if (command === "status") {
    line(["Коммандер", data.installed ? data.version : "не установлен"]);
    line(["Окон", data.windows.length]);
    for (const w of data.windows) line([w.id, w.title]);
  } else if (command === "panels") {
    line(["Панель", "Текущая вкладка", "Быстрый фильтр", "Доступные вкладки"]);
    for (const p of data.panels) line([p.panel, p.selected_tab, p.quick_filter, p.tabs.filter(t => t.enabled).map(t => t.id).join(", ")]);
  } else if (command === "tab" || command === "filter") {
    line([data.panel, command === "tab" ? data.selected_tab : data.quick_filter]);
  } else {
    line(["№", ...data.columns.map(c => c.label || String(c.id))]);
    for (const r of data.rows) line([r.viewport_index + 1, ...r.values]);
    if (!data.rows.length) line(["Выведено строк", 0]);
    if (data.next_offset != null) line(["Продолжить с --offset", data.next_offset]);
  }
}

async function main() {
  let request;
  try { request = parse(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; return; }
  if (request.help) { process.stdout.write(help); return; }
  const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
  const { StdioClientTransport } = require("@modelcontextprotocol/sdk/client/stdio.js");
  const client = new Client({ name: "direct-commander-cli", version: require("./package.json").version });
  try {
    await client.connect(new StdioClientTransport({ command: process.execPath, args: [path.join(__dirname, "server.cjs")] }));
    const call = async (operation, args = {}) => {
      const reply = await client.callTool({ name: "commander_" + operation, arguments: args });
      if (reply.isError) throw Error(reply.content[0].text);
      return reply.structuredContent;
    };
    const result = await execute(call, request);
    if (request.values.json) process.stdout.write(JSON.stringify(result) + "\n");
    else render(request.command, result);
  } finally { await client.close(); }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
