# .NET-to-SwiftCoreWeb naming table

[← docs index](README.md)

For developers coming from ASP.NET Core Minimal APIs, here is how the familiar surface maps onto
SwiftCoreWeb's idiomatic-Swift camelCase API.

| ASP.NET Core / .NET | SwiftCoreWeb |
|---|---|
| `WebApplication.CreateBuilder()` | `WebApplication.createBuilder()` |
| `builder.Build()` | `builder.build()` |
| `app.Run()` / `app.RunAsync()` | `try await app.runAsync()` |
| `app.StopAsync()` | `try await app.stopAsync(timeout:)` |
| `app.Urls` | `app.urls` |
| `app.MapGet("/x", handler)` | `app.mapGet("/x") { ctx in ... }` |
| `app.MapPost`/`MapPut`/`MapPatch`/`MapDelete` | `app.mapPost`/`mapPut`/<br>`mapPatch`/`mapDelete` |
| `app.MapGroup("/api")` | `app.mapGroup("/api")` |
| `RequireAuthorization()` | `.requireAuthorization(_:)` |
| `[ApiController]` + `[Route]` | `@Controller(_ prefix:)` |
| `[HttpGet]`/`[HttpPost]`/etc. | `@Get`/`@Post`/`@Put`/`@Patch`/<br>`@Delete`/`@Head`/`@Options`/`@Route` |
| Route constraints (`{id:int}`) | Route constraints:<br>`{id:int}`, `{id:uuid}`, `{page?}`, `{*path}` |
| `IApplicationBuilder.Use(...)` | `app.use { ctx, next in ... }` |
| `IMiddleware` | `Middleware` protocol |
| `app.UseExceptionHandler()` | `app.useExceptionHandler()` |
| `app.UseCors(...)` | `app.useCors { ... }` |
| `app.UseAuthentication()` | `app.useAuthentication(_:)` |
| `app.UseAuthorization()` | `app.useAuthorization(policies:)` |
| `app.UseStaticFiles()` | `app.useStaticFiles(root:)` |
| `[Authorize]` | `auth: .authenticated` / `.roles([...])` / `.policy(...)` / `.scheme(...)` |
| `HttpContext` | `HttpContext` |
| `HttpContext.Request` | `ctx.request` (`HttpRequest`) |
| `HttpContext.Response` | `ctx.response` (`HttpResponse`) |
| `HttpContext.User` (`ClaimsPrincipal`) | `ctx.user` (`ClaimsPrincipal?`) |
| `HttpContext.Items` | `ctx.items` |
| `IResult` / `Results.Ok(...)` | `HttpResult` / `Results.ok(_:)` |
| `Results.Created`/`NoContent`/`BadRequest`/<br>`NotFound`/`Unauthorized`/`Forbid`/`Redirect`/`File`/`Stream` | `Results.created`/`noContent`/`badRequest`/<br>`notFound`/`unauthorized`/`forbidden`/`redirect`/`file`/`stream` |
| `ProblemDetails` | `ProblemDetails` (RFC 9457) |
| Custom exception → status code | `throw HttpError(_:_:)` |
| `IServiceCollection.AddSingleton`/`AddTransient` | `builder.services.addSingleton`/`addTransient` |
| `IServiceProvider.GetRequiredService<T>()` | `ctx.services.get(T.self)` |
| `[FromRoute]`/`[FromQuery]`/`[FromHeader]`/<br>`[FromServices]`/`[FromBody]`/`[FromForm]` | Convention-based binding by name/type,<br>or `Header<T>`/`Query<T>`/`Service<T>`/`Form` |
| `appsettings.json` / `appsettings.{Environment}.json` | `appsettings.json` / `appsettings.Development.json` |
| `IHostEnvironment.EnvironmentName` | `builder.environment` (`.development` / `.production`) |
| `IConfiguration` typed options | Typed `Codable` options:<br>`ServerOptions`, `CorsOptions`, `RateLimitOptions`, `AuthOptions` |
| ASP.NET Core rate limiting middleware | `builder.rateLimit { ... }`<br>(token-bucket, pre-pipeline) |
| Kestrel | The single NIOTransportServices-backed `ServerEngine` |
| `app.UseWebSockets()` + a handler | `app.mapWebSocket(_:_:)` |
| Server-Sent Events (manual) | `app.mapSse(_:_:)` (`SseWriter`/`SseEvent`) |
| Swashbuckle / `AddOpenApi()` | `app.mapOpenApi(title:version:models:)`<br>(`/openapi.json`) |
| A DTO's OpenAPI schema (reflection-based) | `@ApiModel` (compile-time, no reflection) |
| Razor Pages / views | `View("page.html", model:)`<br>+ the `[[ ]]`-delimited template engine |
| `TestServer` / `WebApplicationFactory` | `SwiftCoreWebTesting.TestHost` |
