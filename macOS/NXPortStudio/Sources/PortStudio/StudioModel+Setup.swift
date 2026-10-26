import Foundation
import PortCore

extension StudioModel {
    func prepareEnvironment() {
        guard !isBusy else { return }
        isBusy = true; status = "Preparing environment"; failure = nil; page = .log
        stageName = ""; stepName = ""; progress = nil; completedURL = nil
        let commands = EnvironmentSetup.commands(pythonURL: ToolEnvironment.defaultPythonURL, venvURL: supportURL.appendingPathComponent("venv"), dependencies: dependencies)
        let runID = UUID(); operationID = runID
        currentTask = Task { [self] in
            do {
                for (index, command) in commands.enumerated() {
                    try Task.checkCancellation()
                    stageIndex = index + 1; stageTotal = commands.count; stageName = command.redactedDescription
                    appendLog(command.redactedDescription)
                    let result = try await runner.run(command) { [weak self] line in Task { @MainActor in
                        guard let self, self.operationID == runID else { return }
                        self.appendLog(line)
                    } }
                    guard result.exitCode == 0 else { throw PortError.processFailed(result.exitCode, t("Environment setup failed. Review the output above; a system installer may need to be completed in Terminal.")) }
                }
                status = "Environment prepared"; appendLog(t("Environment prepared"))
            } catch is CancellationError { status = "Cancelled" }
            catch { status = "Setup failed"; failure = error.localizedDescription; appendLog(error.localizedDescription) }
            operationID = UUID(); isBusy = false; currentTask = nil
            await checkEnvironment()
            if status == "Environment prepared", !missingRequirements.isEmpty {
                status = "More setup required"
                failure = t("Some tools still need attention. Review Environment for the remaining steps.")
                page = .environment
            }
        }
    }
}
