function formEncode(data) {
  return new URLSearchParams(data).toString();
}

function extractCookies(response) {
  let cookies = [];

  if (typeof response.headers.getSetCookie === "function") {
    cookies = response.headers.getSetCookie();
  } else {
    const raw = response.headers.get("set-cookie");

    if (raw) {
      cookies = raw.split(/,(?=[^;,]+=)/);
    }
  }

  return cookies
    .map((cookie) => cookie.split(";")[0].trim())
    .filter(Boolean)
    .join("; ");
}

async function login(username, password) {
  const response = await fetch(
    "https://na.chargepoint.com/users/validate",
    {
      method: "POST",
      headers: {
        origin: "https://na.chargepoint.com",
        accept: "*/*",
        "accept-language": "en-US,en;q=0.9",
        "x-requested-with": "XMLHttpRequest",
        pragma: "no-cache",
        "cache-control": "no-cache",
        "content-type":
          "application/x-www-form-urlencoded; charset=UTF-8",
        referer: "https://na.chargepoint.com/home",
        "user-agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
          "AppleWebKit/537.36 (KHTML, like Gecko) " +
          "Chrome/151.0.0.0 Safari/537.36",
      },
      body: formEncode({
        user_name: username,
        user_password: password,
        auth_code: "",
        recaptcha_response_field: "",
        timezone_offset: "420",
        timezone: "PDT",
        timezone_name: "",
      }),
    }
  );

  const text = await response.text();

  let data;

  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(
      `Login returned non-JSON. HTTP ${response.status}: ${text.slice(
        0,
        300
      )}`
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

  const cookie = extractCookies(response);

  if (!cookie) {
    throw new Error(
      "Login succeeded but ChargePoint returned no session cookie"
    );
  }

  return cookie;
}

async function joinWaitlist(
  cookie,
  waitlistId,
  untilTime
) {
  const response = await fetch(
    "https://na.chargepoint.com/community/activateRegion",
    {
      method: "POST",
      headers: {
        origin: "https://na.chargepoint.com",
        accept:
          "application/json, text/javascript, */*; q=0.01",
        "accept-language": "en-US,en;q=0.9",
        "x-requested-with": "XMLHttpRequest",
        pragma: "no-cache",
        "cache-control": "no-cache",
        "content-type":
          "application/x-www-form-urlencoded; charset=UTF-8",
        referer:
          "https://na.chargepoint.com/dashboard_driver",
        cookie,
        "user-agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
          "AppleWebKit/537.36 (KHTML, like Gecko) " +
          "Chrome/151.0.0.0 Safari/537.36",
      },
      body: formEncode({
        regionIds: waitlistId,
        untilTime,
      }),
    }
  );

  const text = await response.text();

  let data;

  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(
      `Join returned non-JSON. HTTP ${response.status}: ${text.slice(
        0,
        300
      )}`
    );
  }

  return data;
}

async function runAccount({
  name,
  username,
  password,
  waitlistId,
  untilTime,
}) {
  if (!username) {
    throw new Error(`${name}: username secret is missing`);
  }

  if (!password) {
    throw new Error(`${name}: password secret is missing`);
  }

  if (!waitlistId) {
    throw new Error(`${name}: waitlist ID secret is missing`);
  }

  console.log(`${name}: logging in`);

  const cookie = await login(
    username,
    password
  );

  console.log(`${name}: login successful`);

  console.log(
    `${name}: login returned ${
      cookie.split(";").length
    } cookies`
  );

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

  const status =
    result?.status ?? 0;

  console.log(
    `${name}: status=${status} message=${message}`
  );

  return {
    name,
    status,
    message,
  };
}

async function runJeffrey(env) {
  const untilTime =
    env.CHARGEPOINT_UNTIL_TIME || "23";

  return runAccount({
    name: "JEFFREY",
    username: env.CHARGEPOINT_USER,
    password: env.CHARGEPOINT_PASSWD,
    waitlistId:
      env.CHARGEPOINT_WAITLIST_ID,
    untilTime,
  });
}

function serializeResult(result) {
  if (result.status === "fulfilled") {
    return {
      status: "fulfilled",
      value: result.value,
    };
  }

  return {
    status: "rejected",
    error:
      result.reason?.message ??
      String(result.reason),
  };
}

async function runAccounts(env) {
  const results =
    await Promise.allSettled([
      runJeffrey(env),
    ]);

  return results;
}

export default {
  async scheduled(
    controller,
    env,
    ctx
  ) {
    console.log(
      `Cron fired at ${new Date(
        controller.scheduledTime
      ).toISOString()}`
    );

    ctx.waitUntil(
      runAccounts(env)
    );
  },

  async fetch(request, env) {
    const url =
      new URL(request.url);

    if (url.pathname === "/") {
      return new Response(
        "ChargePoint automation Worker is running."
      );
    }

    if (url.pathname === "/test") {
      const results =
        await runAccounts(env);

      return Response.json({
        ok: true,
        results:
          results.map(
            serializeResult
          ),
      });
    }

    return new Response(
      "Not found",
      {
        status: 404,
      }
    );
  },
};
