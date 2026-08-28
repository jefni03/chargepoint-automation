export default {
  async fetch() {
    return new Response("ChargePoint Worker deployed successfully.");
  },

  async scheduled(controller, env, ctx) {
    console.log(
      `Scheduled Worker fired at ${new Date(
        controller.scheduledTime
      ).toISOString()}`
    );
  },
};
