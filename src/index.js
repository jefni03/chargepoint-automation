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
        "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
        "x-requested-with": "XMLHttpRequest",
        origin: "https://na.chargepoint.com",
        referer: "https://na.chargepoint.com/home",
        accept: "*/*",
        "user-agent": "Mozilla/5.0",
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

    runAccount({
      name: "AILEEN",
      username: env.CHARGEPOINT_USER_AILEEN,
      password: env.CHARGEPOINT_PASSWD_AILEEN,
      waitlistId: env.CHARGEPOINT_WAITLIST_ID_AILEEN,
      untilTime,
    }),
  ]);

  for (const result of results) {
    if (result.status === "fulfilled") {
      console.log(
        `${result.value.name}: completed with status=${result.value.status}`
      );
    } else {
      console.error(`Account failed: ${result.reason?.message ?? result.reason}`);
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

      return Response.json({
        ok: true,
        results,
      });
    }

    return new Response("Not found", {
      status: 404,
    });
  },
};
