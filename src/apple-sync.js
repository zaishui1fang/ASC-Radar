const crypto = require("crypto");

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => data += chunk);
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function normalizeStatus(status) {
  const raw = String(status || "NO_VERSION").toUpperCase();
  if (raw === "READY_FOR_SALE") return "READY_FOR_DISTRIBUTION";
  return raw;
}

function shouldDisplayExtraReview(status) {
  const normalized = normalizeStatus(status);
  return !["", "UNKNOWN", "COMPLETED", "STOPPED", "REMOVED"].includes(normalized);
}

function getRelationshipId(resource, names) {
  for (const name of names) {
    const rel = resource?.relationships?.[name]?.data;
    if (rel?.id) return String(rel.id);
  }
  return "";
}

function getExtraReviewPriority(status) {
  const normalized = normalizeStatus(status);
  const priority = {
    UNRESOLVED_ISSUES: 90,
    REJECTED: 80,
    IN_REVIEW: 70,
    WAITING_FOR_REVIEW: 60,
    READY_FOR_REVIEW: 50,
    PREPARE_FOR_SUBMISSION: 40,
    ACCEPTED: 30,
    APPROVED: 30,
    CANCELING: 20,
    COMPLETING: 20
  };
  return priority[normalized] || 0;
}

function upsertExtraReview(map, item) {
  if (!item?.id || !item?.type) return;
  const status = normalizeStatus(item.status);
  if (!shouldDisplayExtraReview(status)) return;

  const key = `${item.type}:${item.id}`;
  const existing = map.get(key);
  if (!existing || getExtraReviewPriority(status) >= getExtraReviewPriority(existing.status)) {
    map.set(key, {
      id: String(item.id),
      type: item.type,
      typeLabel: item.typeLabel,
      name: item.name || item.typeLabel,
      status,
      reviewSubmissionState: item.reviewSubmissionState || "",
      reviewSubmissionId: item.reviewSubmissionId || "",
      itemState: item.itemState || "",
      reviewRequired: item.reviewRequired === true,
      submittedAt: item.submittedAt || "",
      updatedAt: item.updatedAt || ""
    });
  }
}

async function readExtraReviews(account, appId) {
  const reviews = new Map();
  let error = "";

  try {
    const endpoint = `/v1/apps/${encodeURIComponent(appId)}/appStoreVersionExperimentsV2?fields%5BappStoreVersionExperiments%5D=name,state,reviewRequired,platform,startDate,endDate&limit=50`;
    const body = await ascGet(account, endpoint, 10000);
    const experiments = Array.isArray(body.data) ? body.data : [];
    for (const experiment of experiments) {
      const attr = experiment.attributes || {};
      upsertExtraReview(reviews, {
        id: experiment.id,
        type: "PRODUCT_PAGE_OPTIMIZATION",
        typeLabel: "产品页面优化",
        name: attr.name || "产品页面优化",
        status: attr.state || "UNKNOWN",
        reviewRequired: attr.reviewRequired === true,
        updatedAt: attr.startDate || attr.endDate || ""
      });
    }
  } catch (err) {
    error = err?.message || String(err);
  }

  try {
    const endpoint = `/v1/apps/${encodeURIComponent(appId)}/reviewSubmissions?include=items&fields%5BreviewSubmissions%5D=state,submittedDate,items,platform&fields%5BreviewSubmissionItems%5D=state,appStoreVersionExperiment,appStoreVersionExperimentV2,appCustomProductPageVersion&limit=20&limit%5Bitems%5D=50`;
    const body = await ascGet(account, endpoint, 10000);
    const submissions = Array.isArray(body.data) ? body.data : [];
    const included = Array.isArray(body.included) ? body.included : [];
    const submissionByItemId = new Map();

    for (const submission of submissions) {
      const items = submission.relationships?.items?.data || [];
      for (const item of items) {
        if (item?.id) {
          submissionByItemId.set(String(item.id), {
            id: submission.id || "",
            state: normalizeStatus(submission.attributes?.state || ""),
            submittedAt: submission.attributes?.submittedDate || ""
          });
        }
      }
    }

    for (const item of included.filter((entry) => entry.type === "reviewSubmissionItems")) {
      const experimentId = getRelationshipId(item, ["appStoreVersionExperimentV2", "appStoreVersionExperiment"]);
      const customPageId = getRelationshipId(item, ["appCustomProductPageVersion"]);
      if (!experimentId && !customPageId) continue;

      const submission = submissionByItemId.get(String(item.id)) || {};
      const itemState = normalizeStatus(item.attributes?.state || "UNKNOWN");
      const submissionState = normalizeStatus(submission.state || "");
      const status = shouldDisplayExtraReview(submissionState) ? submissionState : itemState;

      upsertExtraReview(reviews, {
        id: experimentId || customPageId,
        type: experimentId ? "PRODUCT_PAGE_OPTIMIZATION" : "CUSTOM_PRODUCT_PAGE",
        typeLabel: experimentId ? "产品页面优化" : "自定义产品页",
        name: experimentId ? "产品页面优化" : "自定义产品页",
        status,
        reviewSubmissionState: submissionState,
        reviewSubmissionId: submission.id || "",
        itemState,
        submittedAt: submission.submittedAt || ""
      });
    }
  } catch (err) {
    const message = err?.message || String(err);
    error = error ? `${error}; ${message}` : message;
  }

  return {
    items: Array.from(reviews.values()).sort((a, b) => {
      const priority = getExtraReviewPriority(b.status) - getExtraReviewPriority(a.status);
      if (priority !== 0) return priority;
      return String(a.typeLabel).localeCompare(String(b.typeLabel));
    }),
    error
  };
}

function isDeletedAppError(error) {
  const message = String(error?.message || "");
  return /Apple API 404\b/.test(message) || /not\s+found/i.test(message);
}

function materializeImageUrl(asset) {
  if (!asset) return "";
  const template = asset.templateUrl || asset.templateURL || asset.url || "";
  if (!template) return "";
  return String(template)
    .replace(/\{w\}/g, "100")
    .replace(/\{h\}/g, "100")
    .replace(/\{c\}/g, "bb")
    .replace(/\{f\}/g, "png")
    .replace(/\{quality\}/g, "80")
    .replace(/\{scale\}/g, "2");
}

function createJwt(account) {
  if (!account.privateKey) throw new Error("缺少 .p8 私钥");
  if (!account.issuerId || !account.keyId) throw new Error("缺少 Issuer ID 或 Key ID");

  const header = { alg: "ES256", kid: account.keyId, typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: account.issuerId,
    iat: now,
    exp: now + 20 * 60,
    aud: "appstoreconnect-v1"
  };
  const enc = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  const signingInput = `${enc(header)}.${enc(payload)}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: account.privateKey,
    dsaEncoding: "ieee-p1363"
  }).toString("base64url");
  return `${signingInput}.${signature}`;
}

async function fetchWithTimeout(url, options = {}, timeoutMs = 30000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function ascGet(account, endpoint, timeoutMs = 15000) {
  const token = createJwt(account);
  const response = await fetchWithTimeout(`https://api.appstoreconnect.apple.com${endpoint}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json"
    }
  }, timeoutMs);
  const text = await response.text();
  let body = {};
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text };
  }
  if (!response.ok) {
    const detail = body.errors?.[0]?.detail || body.errors?.[0]?.title || text || response.statusText;
    throw new Error(`Apple API ${response.status}: ${detail}`);
  }
  return body;
}

async function publicLookupIcon(appId, bundleId) {
  const queries = [];
  const countries = ["cn", "us"];
  for (const country of countries) {
    const suffix = `&country=${country}`;
    if (bundleId) queries.push(`https://itunes.apple.com/lookup?bundleId=${encodeURIComponent(bundleId)}${suffix}`);
    if (appId) queries.push(`https://itunes.apple.com/lookup?id=${encodeURIComponent(appId)}${suffix}`);
  }

  const lookups = await Promise.all(queries.map(async (url) => {
    try {
      const response = await fetchWithTimeout(url, { headers: { Accept: "application/json" } }, 2500);
      if (!response.ok) return "";
      const body = await response.json();
      const app = Array.isArray(body.results) ? body.results[0] : null;
      return app?.artworkUrl512 || app?.artworkUrl100 || app?.artworkUrl60 || "";
    } catch {
      return "";
    }
  }));
  const icon = lookups.find((value) => value);
  if (icon) return icon;
  return "";
}

async function getVersionBuild(account, versionId) {
  if (!versionId) return null;
  try {
    const body = await ascGet(account, `/v1/appStoreVersions/${versionId}/build`);
    return body?.data || null;
  } catch {
    return null;
  }
}

async function getLatestBuild(account, appId) {
  const endpoints = [
    `/v1/builds?filter%5Bapp%5D=${encodeURIComponent(appId)}&limit=5&sort=-uploadedDate`,
    `/v1/apps/${appId}/builds?limit=5&sort=-uploadedDate`
  ];

  for (const endpoint of endpoints) {
    try {
      const body = await ascGet(account, endpoint);
      const builds = Array.isArray(body.data) ? body.data : [];
      if (builds.length > 0) return builds[0];
    } catch {
      // Some API versions/roles do not expose one of these routes.
    }
  }
  return null;
}

async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;
  async function run() {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      results[index] = await worker(items[index], index);
    }
  }
  const runners = [];
  for (let i = 0; i < Math.min(limit, items.length); i++) runners.push(run());
  await Promise.all(runners);
  return results;
}

async function readApp(account, item, knownIcons) {
  const appId = item.id;
  const attr = item.attributes || {};
  let version = null;
  let build = null;
  let iconUrl = "";
  let status = "NO_VERSION";
  let versionError = "";
  let extraReviews = [];
  let extraReviewError = "";

  try {
    const appWithVersions = await ascGet(account, `/v1/apps/${appId}?include=appStoreVersions`);
    const versions = Array.isArray(appWithVersions.included)
      ? appWithVersions.included.filter((entry) => entry.type === "appStoreVersions")
      : [];
    version = versions.find((entry) => entry.attributes?.appStoreState && entry.attributes.appStoreState !== "READY_FOR_SALE")
      || versions[0]
      || null;
    if (version?.attributes?.appStoreState) {
      status = normalizeStatus(version.attributes.appStoreState);
    } else {
      status = "NO_VERSION";
    }
  } catch (error) {
    if (isDeletedAppError(error)) {
      return {
        appleId: appId,
        name: attr.name || "未命名 App",
        bundleId: attr.bundleId || "",
        sku: attr.sku || "",
        primaryLocale: attr.primaryLocale || "",
        platform: "iOS",
        version: "",
        build: "",
        buildId: "",
        iconUrl: "",
        processingState: "",
        status: "DELETED",
        deleted: true,
        versionError: error.message,
        submittedAt: "",
        updatedAt: ""
      };
    }
    status = "UNKNOWN";
    versionError = error.message;
  }

  build = await getVersionBuild(account, version?.id) || await getLatestBuild(account, appId);

  const extraReviewResult = await readExtraReviews(account, appId);
  extraReviews = extraReviewResult.items;
  extraReviewError = extraReviewResult.error;

  const known = knownIcons[appId] || {};
  if (build?.id && known.buildId === build.id && known.iconUrl) {
    iconUrl = known.iconUrl;
  } else if (build?.id) {
    try {
      const iconsBody = await ascGet(account, `/v1/builds/${build.id}/icons?limit=10`);
      const icons = Array.isArray(iconsBody.data) ? iconsBody.data : [];
      const icon = icons.find((entry) => entry.attributes?.iconAsset) || icons[0] || null;
      iconUrl = materializeImageUrl(icon?.attributes?.iconAsset);
    } catch {
      iconUrl = "";
    }
  }
  if (!iconUrl && (!build?.id || status === "READY_FOR_DISTRIBUTION")) {
    iconUrl = await publicLookupIcon(appId, attr.bundleId || "");
  }

  return {
    appleId: appId,
    name: attr.name || "未命名 App",
    bundleId: attr.bundleId || "",
    sku: attr.sku || "",
    primaryLocale: attr.primaryLocale || "",
    platform: "iOS",
    version: version?.attributes?.versionString || "",
    build: build?.attributes?.version || "",
    buildId: build?.id || "",
    iconUrl,
    processingState: build?.attributes?.processingState || "",
    status,
    versionError,
    extraReviews,
    extraReviewError,
    submittedAt: version?.attributes?.createdDate || "",
    updatedAt: version?.attributes?.createdDate || build?.attributes?.uploadedDate || ""
  };
}

async function readAppStatus(account, item) {
  const appId = item.appleId || item.id;
  let version = null;
  let status = "NO_VERSION";
  let versionError = "";
  let extraReviews = [];
  let extraReviewError = "";

  try {
    const appWithVersions = await ascGet(account, `/v1/apps/${appId}?include=appStoreVersions`, 10000);
    const versions = Array.isArray(appWithVersions.included)
      ? appWithVersions.included.filter((entry) => entry.type === "appStoreVersions")
      : [];
    version = versions.find((entry) => entry.attributes?.appStoreState && entry.attributes.appStoreState !== "READY_FOR_SALE")
      || versions[0]
      || null;
    status = version?.attributes?.appStoreState
      ? normalizeStatus(version.attributes.appStoreState)
      : "NO_VERSION";
  } catch (error) {
    if (isDeletedAppError(error)) {
      return {
        appleId: appId,
        name: item.name || "",
        bundleId: item.bundleId || "",
        version: "",
        status: "DELETED",
        deleted: true,
        versionError: error.message,
        submittedAt: "",
        updatedAt: ""
      };
    }
    status = "UNKNOWN";
    versionError = error.message;
  }

  if (status !== "DELETED") {
    const extraReviewResult = await readExtraReviews(account, appId);
    extraReviews = extraReviewResult.items;
    extraReviewError = extraReviewResult.error;
  }

  return {
    appleId: appId,
    name: item.name || "",
    bundleId: item.bundleId || "",
    version: version?.attributes?.versionString || "",
    status,
    versionError,
    extraReviews,
    extraReviewError,
    submittedAt: version?.attributes?.createdDate || "",
    updatedAt: version?.attributes?.createdDate || ""
  };
}

async function main() {
  const input = JSON.parse(await readStdin());
  const account = input.account;
  const knownIcons = input.knownIcons || {};
  const mode = input.mode || "full";

  if (mode === "status") {
    const trackedApps = Array.isArray(input.trackedApps) ? input.trackedApps.filter((app) => app.appleId || app.id) : [];
    const result = await mapLimit(trackedApps, 4, (item) => readAppStatus(account, item));
    process.stdout.write(JSON.stringify({ ok: true, mode, apps: result }));
    return;
  }

  const appsBody = await ascGet(account, "/v1/apps?limit=200&sort=name");
  const apps = Array.isArray(appsBody.data) ? appsBody.data : [];

  if (mode === "discover") {
    const knownIds = new Set(Array.isArray(input.trackedApps)
      ? input.trackedApps.map((app) => String(app.appleId || app.id || "")).filter(Boolean)
      : []);
    const newApps = apps.filter((item) => item?.id && !knownIds.has(String(item.id)));
    const result = await mapLimit(newApps, 2, (item) => readApp(account, item, knownIcons));
    process.stdout.write(JSON.stringify({ ok: true, mode, apps: result, scannedCount: apps.length, newCount: result.length }));
    return;
  }

  const result = await mapLimit(apps, 3, (item) => readApp(account, item, knownIcons));

  process.stdout.write(JSON.stringify({ ok: true, apps: result }));
}

main().catch((error) => {
  process.stdout.write(JSON.stringify({ ok: false, error: error.message }));
  process.exitCode = 1;
});



