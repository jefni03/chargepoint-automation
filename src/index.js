function formEncode(data) {
  return new URLSearchParams(data).toString();
}

function extractCookies(response) {
  const raw = response.headers.get("set-cookie");
  if (!raw) return "";

  return raw
    .split(/,(?=[^;,]+=)/)
    .map((cookie) => cookie.split(";")[0])
    .join("; ");
}

async function login(username, password) {
  const response = await fetch(
    "https://na.chargepoint.com/users/validate",
    {
      method: "POST",
      headers: {
        "origin": "https://na.chargepoint.com",
        "accept": "*/*",
        "accept-language": "en-US,en;q=0.9",
        "x-requested-with": "XMLHttpRequest",
        "pragma": "no-cache",
        "cache-control": "no-cache",
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
        "referer": "https://na.chargepoint.com/home",
        "user-agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36",
      },

      body: new URLSearchParams({
        user_name: username,
        user_password: password,
        auth_code: "",
        recaptcha_response_field: "",
        timezone_offset: "420",
        timezone: "PDT",
        timezone_name: "",
      }).toString(),
    }
  );

  const text = await response.text();

  let data;

  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(
      `Login returned non-JSON. HTTP ${response.status}: ${text.slice(0, 300)}`
    );
  }

  if (!data.auth) {
    const safeData = {
      httpStatus: response.status,
      auth: data.auth,
      status: data.status,
      message: data.message,
      error: data.error,
      redirect_url: data.redirect_url,
      org_sso_login_enabled: data.org_sso_login_enabled,
    };

    throw new Error(
      `ChargePoint login rejected: ${JSON.stringify(safeData)}`
    );
  }

  const rawCookies = response.headers.get("set-cookie");

  if (!rawCookies) {
    throw new Error("Login succeeded but ChargePoint returned no Set-Cookie header");
  }

  const cookie = rawCookies
    .split(/,(?=[^;,]+=)/)
    .map((c) => c.split(";")[0])
    .join("; ");

  return cookie;
}
  const text = await response.text();

  let data;

  try {
    data = JSON.parse(text);
  } catch {
    throw new Error("Login returned a non-JSON response");
  }

  if (!data.auth) {
    throw new Error("ChargePoint login rejected");
  }

  const cookie = extractCookies(response);

  if (!cookie) {
    throw new Error("ChargePoint did not return a session cookie");
  }

  return cookie;
}

async function joinWaitlist(cookie, waitlistId, untilTime) {
  const response = await fetch(
    "https://na.chargepoint.com/community/activateRegion",
    {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
        "x-requested-with": "XMLHttpRequest",
        origin: "https://na.chargepoint.com",
        referer: "https://na.chargepoint.com/dashboard_driver",
        accept: "application/json, text/javascript, */*; q=0.01",
        cookie,
        "user-agent": "Mozilla/5.0",
      },
      body: formEncode({
        regionIds: waitlistId,
        untilTime,
      }),
    }
  );

  const text = await response.text();

  try {
    return JSON.parse(text);
  } catch {
    throw new Error(
      `Join returned non-JSON response: ${text.slice(0, 200)}`
    );
  }
}

async function runAccount({
  name,
  username,
  password,
  waitlistId,
  untilTime,
}) {
  console.log(`${name}: logging in`);

  const cookie = await login(username, password);

  console.log(`${name}: login successful`);

  const result = await joinWaitlist(
    cookie,
    waitlistId,
    untilTime
  );

  const message =
    result?.response?.message ??
    result?.response?.error ??
    result?.message ??
    result?.error ??
    "No message returned";

  console.log(
    `${name}: status=${result?.status ?? "missing"} message=${message}`
  );

  return {
    name,
    status: result?.status ?? 0,
    message,
  };
}

async function runBothAccounts(env) {
  const untilTime =
    env.CHARGEPOINT_UNTIL_TIME || "23";

  const results = await Promise.allSettled([
    runAccount({
      name: "JEFFREY",
      username: env.CHARGEPOINT_USER,
      password: env.CHARGEPOINT_PASSWD,
      waitlistId: env.CHARGEPOINT_WAITLIST_ID,
      untilTime,
    }),
  ]);

  for (const result of results) {
    if (result.status === "fulfilled") {
      console.log(
        `${result.value.name}: completed with status=${result.value.status}`
      );
    } else {
      console.error(
        `Account failed: ${result.reason?.message ?? result.reason}`
      );
    }
  }

  return results;
}

export default {
  async scheduled(controller, env, ctx) {
    console.log(
      `Cron fired at ${new Date(
        controller.scheduledTime
      ).toISOString()}`
    );

    ctx.waitUntil(runBothAccounts(env));
  },

  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return new Response(
        "ChargePoint automation Worker is running."
      );
    }

    // Temporary manual test endpoint.
    if (url.pathname === "/test") {
  const results = await runBothAccounts(env);

  const cleaned = results.map((result) => {
    if (result.status === "fulfilled") {
      return {
        status: "fulfilled",
        value: result.value,
      };
    }

    return {
      status: "rejected",
      error: result.reason?.message || String(result.reason),
    };
  });

  return Response.json({
    ok: true,
    results: cleaned,
  });
}

    return new Response("Not found", {
      status: 404,
    });
  },
};
