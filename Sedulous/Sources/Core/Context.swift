import Foundation
import SedulousFoundation;

public typealias ContextInitializingCallback = (_ initializer: ContextInitializer) -> Void;
public typealias ContextInitializedCallback = (_ context: Context) -> Void;
public typealias ContextShuttingDownCallback = (_ context: Context) -> Void;

public enum ContextUpdateStage : CaseIterable
{
    case preUpdate
    case postUpdate
    case variableUpdate
    case fixedUpdate
}

public struct ContextUpdateInfo
{
    public var context: Context;
    public var time: Time;
}

public typealias ContextUpdateFunction = (_ info : ContextUpdateInfo) -> Void

public struct ContextUpdateFunctionInfo
{
    public var priority : Int;
    public var stage : ContextUpdateStage;
    public var function : ContextUpdateFunction;

    public init(function: @escaping ContextUpdateFunction, priority: Int = 0, stage: ContextUpdateStage = .variableUpdate)
    {
        self.priority = priority;
        self.stage = stage;
        self.function = function;
    }
}

public class Context
{
    fileprivate struct RegisteredUpdateFunctionInfo
	{
        public var id: RegisteredUpdateFunctionID;
		public var priority: Int;
		public var function: ContextUpdateFunction;
	}

    public typealias RegisteredUpdateFunctionID = (id: UUID, stage: ContextUpdateStage);

    public private(set) var host: ContextHost;

    private let preUpdateTimeTracker: TimeTracker = .init();
    private let postUpdateTimeTracker: TimeTracker = .init();
    private let variableUpdateTimeTracker: TimeTracker = .init();
    private let fixedUpdateTimeTracker: TimeTracker = .init();

    private var accumulatedElapsedTime: Int64 = 0;

    public static let maxElapsedTime: TimeSpan = try! .fromMilliseconds(500);
    public static let defaultTargetElapsedTime: TimeSpan = try! .init(ticks: TimeSpan.ticksPerSecond/60);
    public static let defaultInactiveSleepTime: TimeSpan = try! .fromMilliseconds(20);

    public var targetElapsedTime: TimeSpan = defaultTargetElapsedTime;
    public var inactiveSleepTime: TimeSpan = defaultInactiveSleepTime;

    private var updateFunctions: Dictionary<ContextUpdateStage, Array<RegisteredUpdateFunctionInfo>> = .init();
	private var updateFunctionsToRegister: Array<RegisteredUpdateFunctionInfo> = .init();
	private var updateFunctionIdsToUnregister: Array<RegisteredUpdateFunctionID> = .init();

    private var systems: [System] = .init();

    package init(_ host: ContextHost)
    {
        self.host = host;

        for stage: ContextUpdateStage in ContextUpdateStage.allCases
        {
            updateFunctions[stage] = .init();
        }
    }
}

package extension Context
{
    func initialize(_ initializer: ContextInitializer)
    {
        var initializedSystems: [System] = .init();

        for system in initializer.systems {
            if system.initialize(self) {
                initializedSystems.append(system);
            }else{
                break;
            }
        }

        if initializedSystems.count != initializer.systems.count {
            for system in initializedSystems.reversed() {
                system.shutdown();
            }
            return;
        }

        systems.append(contentsOf: initializedSystems);
    }

    func shutdown()
    {
        for system in systems.reversed() {
            system.shutdown();
        }
    }
} 

extension Context
{
    fileprivate func sortUpdateFunctions()
    {
        for stage: ContextUpdateStage in ContextUpdateStage.allCases
        {
            updateFunctions[stage]!.sort { lhs, rhs in
                return lhs.priority > rhs.priority
            }
        }
    }

    fileprivate func runUpdateFunctions(_ phase: ContextUpdateStage , _ info: ContextUpdateInfo)
    {
        for updateFunctionInfo: RegisteredUpdateFunctionInfo in updateFunctions[phase]!
        {
            updateFunctionInfo.function(info);
        }
    }
    
    fileprivate func processUpdateFunctionsToRegister()
    {
        if updateFunctionsToRegister.count == 0 { return; }

        for info: RegisteredUpdateFunctionInfo in updateFunctionsToRegister
        {
            updateFunctions[info.id.stage]!.append(info);
        }
        updateFunctionsToRegister.removeAll();
        sortUpdateFunctions();
    }
    
    fileprivate func processUpdateFunctionsToUnregister()
    {
        if updateFunctionIdsToUnregister.count == 0 { return; }

        for entry: RegisteredUpdateFunctionID in updateFunctionIdsToUnregister
        {
            if let index: Array<RegisteredUpdateFunctionInfo>.Index = updateFunctions[entry.stage]!.firstIndex(where: { registered in
                return registered.id.id == entry.id;
            }) {
                updateFunctions[entry.stage]!.remove(at: index);
            }
        }
        updateFunctionIdsToUnregister.removeAll();
        sortUpdateFunctions();
    }

    package func update(_ time: Time)
    {
        do {
			processUpdateFunctionsToRegister();
			processUpdateFunctionsToUnregister();
		}

        if inactiveSleepTime.totalSeconds > 0 && host.suspended  {
            Thread.sleep(forTimeInterval: TimeInterval(inactiveSleepTime.totalSeconds));
        }

        accumulatedElapsedTime += time.elapsedTime.ticks;
        if accumulatedElapsedTime > Self.maxElapsedTime.ticks {
            accumulatedElapsedTime = Self.maxElapsedTime.ticks;
        }

        // Pre-Update
        do {
            runUpdateFunctions(.preUpdate, .init(
					context: self,
					time: preUpdateTimeTracker.increment(time.elapsedTime)
            ));
        }

        // Fixed Update
        do {
            let fixedTicksToRun: Int64 = accumulatedElapsedTime / targetElapsedTime.ticks;

            if fixedTicksToRun > 0 {
                let fixedUpdateTimeDelta: TimeSpan = targetElapsedTime;
                accumulatedElapsedTime -= fixedTicksToRun * targetElapsedTime.ticks;

                for _ in 0..<fixedTicksToRun {
                    runUpdateFunctions(.fixedUpdate, .init(
                        context: self,
                        time: fixedUpdateTimeTracker.increment(fixedUpdateTimeDelta)
                    ));
                }
            }
        }


        // Variable Update
        do {
            runUpdateFunctions(.variableUpdate, .init(
					context: self,
					time: variableUpdateTimeTracker.increment(time.elapsedTime)
            ));
        }

        // Post Update
        do {
            runUpdateFunctions(.postUpdate, .init(
                context: self,
				time: postUpdateTimeTracker.increment(time.elapsedTime)
            ));
        }
    }

    public func registerUpdateFunction(_ info: ContextUpdateFunctionInfo) -> RegisteredUpdateFunctionID {
        let registered: RegisteredUpdateFunctionInfo = .init(id: (id: UUID(), stage: info.stage), priority: info.priority, function: info.function);
        updateFunctionsToRegister.append(registered);
        return registered.id;
    }

    public func registerUpdateFunctions(_ infos: Array<ContextUpdateFunctionInfo>) -> [RegisteredUpdateFunctionID] {
        var ids: [RegisteredUpdateFunctionID] = .init();
        for info: ContextUpdateFunctionInfo in infos
		{
			ids.append(registerUpdateFunction(info));
		}
        return ids;
    }

    public func unregisterUpdateFunction(_ id: RegisteredUpdateFunctionID) {
        updateFunctionIdsToUnregister.append(id);
    }

    public func unregisterUpdateFunctions(_ ids: [RegisteredUpdateFunctionID]) {
        for entry: RegisteredUpdateFunctionID in ids
		{
			updateFunctionIdsToUnregister.append(entry);
		}
    }
} 

public extension Context {
    func getSystem<T>() -> T? where T : System {
        for system: System in systems {
            if let tSystem = system as? T {
                return tSystem;
            }
        }
        return nil;
    }

    func tryGetSystem<T>(_ outSystem: inout T) -> Bool where T : System {
        for system: System in systems {
            if let tSystem = system as? T {
                outSystem = tSystem;
                return true;
            }
        }
        return false;
    }
}