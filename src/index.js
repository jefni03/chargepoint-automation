function formEncode(data) {
  return new URLSearchParams(data).toString();
}

function getSetCookies(response) {
  if (typeof response.headers.getSetCookie === "function") {
    return response.headers.getSetCookie();
  }

  const raw = response.headers.get("set-cookie");

  if (!raw) {
    return [];
  }

  return raw.split(/,(?=[^;,]+=)/);
}

function cookiesToMap(setCookies) {
  const map = new Map();

  for (const rawCookie of setCookies) {
    const firstPart = rawCookie.split(";")[0].trim();

    const equalsIndex = firstPart.indexOf("=");

    if (equalsIndex === -1) {
      continue;
    }

    const name = firstPart.slice(0, equalsIndex);
    const value = firstPart.slice(equalsIndex + 1);

    map.set(name, value);
  }

  return map;
}

function mergeCookieMaps(base, incoming) {
  const merged = new Map(base);

  for (const [name, value] of incoming.entries()) {
    merged.set(name, value);
  }

  return merged;
}

function cookieHeader(cookieMap) {
  return Array.from(cookieMap.entries())
    .map(([name, value]) => `${name}=${value}`)
    .join("; ");
}

const COMMON_HEADERS = {
  accept: "*/*",
  "accept-language": "en-US,en;q=0.9",
  "user-agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) " +
    "Chrome/151.0.0.0 Safari/537.36",
};

async function establishSession() {
  const response = await fetch(
    "https://na.chargepoint.com/home",
    {
      method: "GET",
      headers: {
        ...COMMON_HEADERS,
      },
      redirect: "follow",
    }
  );

  const cookieMap = cookiesToMap(
    getSetCookies(response)
  );

  console.log(
    `Initial ChargePoint session returned ${cookieMap.size} cookies`
  );

  return cookieMap;
}

async function login(
  username,
  password,
  initialCookies
) {
  const response = await fetch(
    "https://na.chargepoint.com/users/validate",
    {
      method: "POST",

      headers: {
        ...COMMON_HEADERS,

        origin:
          "https://na.chargepoint.com",

        referer:
          "https://na.chargepoint.com/home",

        "x-requested-with":
          "XMLHttpRequest",

        "content-type":
          "application/x-www-form-urlencoded; charset=UTF-8",

        cookie:
          cookieHeader(initialCookies),
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
      org_sso_login_enabled:
        data.org_sso_login_enabled,
    };

    throw new Error(
      `ChargePoint login rejected: ${JSON.stringify(
        safeData
      )}`
    );
  }

  const loginCookies = cookiesToMap(
    getSetCookies(response)
  );

  const allCookies = mergeCookieMaps(
    initialCookies,
    loginCookies
  );

  console.log(
    `Login successful. Session now has ${allCookies.size} cookies`
  );

  return allCookies;
}

async function joinWaitlist(
  cookies,
  waitlistId,
  untilTime
) {
  const response = await fetch(
    "https://na.chargepoint.com/community/activateRegion",
    {
      method: "POST",

      headers: {
        ...COMMON_HEADERS,

        origin:
          "https://na.chargepoint.com",

        referer:
          "https://na.chargepoint.com/dashboard_driver",

        accept:
          "application/json, text/javascript, */*; q=0.01",

        "x-requested-with":
          "XMLHttpRequest",

        "content-type":
          "application/x-www-form-urlencoded; charset=UTF-8",

        cookie:
          cookieHeader(cookies),
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
    throw new Error(
      `${name}: username secret is missing`
    );
  }

  if (!password) {
    throw new Error(
      `${name}: password secret is missing`
    );
  }

  if (!waitlistId) {
    throw new Error(
      `${name}: waitlist ID secret is missing`
    );
  }

  console.log(
    `${name}: establishing ChargePoint session`
  );

  const initialCookies =
    await establishSession();

  console.log(
    `${name}: logging in`
  );

  const cookies =
    await login(
      username,
      password,
      initialCookies
    );

  console.log(
    `${name}: login successful`
  );

  const result =
    await joinWaitlist(
      cookies,
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

async function runAccounts(env) {
  const untilTime =
    env.CHARGEPOINT_UNTIL_TIME || "23";

  return Promise.allSettled([
    runAccount({
      name: "JEFFREY",
      username:
        env.CHARGEPOINT_USER,
      password:
        env.CHARGEPOINT_PASSWD,
      waitlistId:
        env.CHARGEPOINT_WAITLIST_ID,
      untilTime,
    }),

    runAccount({
      name: "AILEEN",
      username:
        env.CHARGEPOINT_USER_AILEEN,
      password:
        env.CHARGEPOINT_PASSWD_AILEEN,
      waitlistId:
        env.CHARGEPOINT_WAITLIST_ID_AILEEN,
      untilTime,
    }),
  ]);
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
