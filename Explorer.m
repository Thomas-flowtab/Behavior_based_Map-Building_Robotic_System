classdef Explorer < handle
    properties
        baseControl  % BaseControl class instance for robot movement
        slamHandler  % SLAMHandler class instance for map updates
        sensor       % Hokuyo sensor (LaserScanner)
        robotPose    % RobotPose class instance for robot position
        robotPosition % Current robot position
        goalPosition  % Frontier goal position
        largestFrontier % Biggest detected frontiers
        planner       % Path planner based on plannerType
        controller    % Pure Pursuit controller
        explorationTimer % Timer for asynchronous exploration
        isExploring      % Boolean flag to check if exploration is active
        connection % Connection to Coppelia
    end
    
    methods
        function obj = Explorer(connection,baseControl, slamHandler, sensor, robotPose)
            obj.connection = connection;
            obj.baseControl = baseControl;  % Instance of BaseControl class for movement
            obj.slamHandler = slamHandler;  % Instance of SLAMHandler class for map updates
            obj.sensor = sensor;            % Hokuyo LaserScanner class instance
            obj.robotPose = robotPose; 

            % Initialize the Pure Pursuit controller
            obj.controller = controllerPurePursuit;
            obj.controller.LookaheadDistance = 0.5;  % Adjust this value as needed
            obj.controller.DesiredLinearVelocity = 0.3;  % Adjust for desired speed
            obj.controller.MaxAngularVelocity = 1.0;  % Maximum rotation speed

            % Initialize exploration flag
            obj.isExploring = false;
            
            % Initialize asynchronous exploration timer
            obj.explorationTimer = timer('ExecutionMode', 'fixedRate', ...
                                         'Period', 1.0, ...
                                         'TimerFcn', @(~,~) obj.exploreAsync(), ...
                                         'BusyMode', 'queue');
        end
        
        function startExploration(obj)
            % Start the asynchronous exploration process using the timer
            if ~obj.isExploring
                obj.isExploring = true;
                start(obj.explorationTimer);
                disp('Exploration started asynchronously');
            end
        end
        
        function stopExploration(obj)
            % Stop the asynchronous exploration process by stopping the timer
            if obj.isExploring
                obj.isExploring = false;
                stop(obj.explorationTimer);
                disp('Exploration stopped');
            end
        end

        function exploreAsync(obj)
            % Asynchronous exploration loop, triggered by the timer
            if obj.isExploring
                occMap = obj.slamHandler.occupancyMapObject;
                
                % Initialize the path planner based on user input

                disp(occMap);
                obj.planner = plannerAStarGrid(occMap);

                % Detect frontiers and set the list of frontiers
                obj.largestFrontier = obj.findLargestFrontier(occMap);
                
                if isempty(obj.largestFrontier)
                    disp('Exploration complete. No more frontiers found.');
                    obj.stopExploration();   % Stop exploration if no frontiers found
                    return;
                end
                
                % Move to the selected frontier
                disp('Move to the selected frontier');
                pathPlanning = obj.createPathPlanningToFrontier(); 

                % Follow the path using Pure Pursuit
                disp('Follow the path using Pure Pursuit');
                obj.followPathWithPurePursuit(pathPlanning);

            end
        end

        function largestFrontier = findLargestFrontier(~,occMap)
            % Function to find the largest frontier on an occupancy map
            %
            % Inputs:
            %   map - occupancyMap object
            %
            % Outputs:
            %   largestFrontier - Nx2 array of [X, Y] coordinates representing the largest frontier
        
            % Define thresholds for free, occupied, and unknown cells
            freeThreshold = occMap.FreeThreshold;          % Default is 0.2
            occupiedThreshold = occMap.OccupiedThreshold;  % Default is 0.65
        
            % Get the occupancy matrix from the map
            occMatrix = getOccupancy(occMap);
            
            % Classify cells based on occupancy probabilities
            freeCells = occMatrix < freeThreshold;
            occupiedCells = occMatrix > occupiedThreshold;
            unknownCells = ~(freeCells | occupiedCells); % Cells with occupancy ~0.5
            
            % Identify frontier cells
            % A frontier cell is a free cell that has at least one unknown neighbor
            % Use convolution to check the 8-connected neighborhood
            kernel = [1 1 1; 1 0 1; 1 1 1];
            unknownNeighborCount = conv2(double(unknownCells), kernel, 'same');
            frontierCells = freeCells & (unknownNeighborCount > 0);
            
            % Label connected components (frontiers)
            % Use 8-connectivity to consider diagonal neighbors
            [labeledFrontiers, numFrontiers] = bwlabel(frontierCells, 8);
            
            % Initialize variables to track the largest frontier
            largestSize = 0;
            largestLabel = 0;
            
            % Iterate through each labeled frontier to find the largest one
            for i = 1:numFrontiers
                % Find the size (number of cells) of the current frontier
                currentSize = sum(labeledFrontiers(:) == i);
                % Update if the current frontier is larger than the previous largest
                if currentSize > largestSize
                    largestSize = currentSize;
                    largestLabel = i;
                end
            end
            
            % Check if any frontiers were found
            if largestLabel == 0
                largestFrontier = [];
                disp('No frontiers found in the map.');
                return;
            end
            
            % Extract the largest frontier based on the label
            largestFrontierMask = (labeledFrontiers == largestLabel);
            
            % Get the grid indices of the largest frontier cells
            [frontierRows, frontierCols] = find(largestFrontierMask);
            
            % Convert grid indices to world coordinates
            if ismethod(occMap, 'grid2world')
                % Method 1: Use grid2world if available
                frontierWorld = occMap.grid2world([frontierCols, frontierRows]);
                frontierX = frontierWorld(:,1);
                frontierY = frontierWorld(:,2);
            else
                % Method 2: Manual conversion using map properties
                resolution = occMap.GridResolution;          % meters per cell
                origin = occMap.GridOriginInWorld;           % [x_origin, y_origin]
                
                frontierX = (frontierCols - 1) * resolution + origin(1);
                frontierY = (frontierRows - 1) * resolution + origin(2);
            end
            
            % Combine X and Y coordinates into an Nx2 array
            largestFrontier = [frontierX, frontierY];
        end
       
        function adjustedPath = createPathPlanningToFrontier(obj)

            obj.getRobotPose();

            obj.goalPosition = [obj.largestFrontier(1),obj.largestFrontier(2)];
            
            disp(obj.goalPosition);

            if isempty(obj.goalPosition)
                disp('No goal position available');
                return;
            end
                        
            % Perform path planning using the initialized planner
            path = plan(obj.planner, obj.robotPosition, obj.goalPosition,'world');

            % Adjust the path by subtracting the initial position
            adjustedPath = path - obj.robotPosition;
            
            % Check if the path is valid
            if isempty(adjustedPath)
                disp('Path could not be found.');
                return;
            end
        end

        function followPathWithPurePursuit(obj, path)
            % Setup the Pure Pursuit controller waypoints from the planned path
            disp('following path now:');

            obj.controller.Waypoints = path;
            
            % Continuously move the robot along the path
            while ~isempty(path) && obj.isExploring
                
                currentPose = obj.getRobotPose();  % Update the robot position
                
                % disp('Compute the control signals');
                % Compute the control signals (linear velocity and angular velocity)
                [v, omega] = obj.controller(currentPose);
                

                % disp('Move the robot');
                % disp('speed');
                % disp(v);
                % disp('angle');
                % disp(omega);

                % Move the robot using BaseControl (assuming BaseControl has move method)
                obj.baseControl.moveRobot(obj.connection,v, omega);  % Move the robot based on Pure Pursuit output
                
                % Update robot's position and the map (this ensures SLAM is being updated)
                obj.slamHandler.updateSLAM(path);
                
                % Check if the robot has reached the goal
                if norm(obj.robotPosition - path(end, :)) < obj.controller.LookaheadDistance
                    disp('Goal reached');
                    break;
                end
            end
        end
        
        function currentPose = getRobotPose(obj)
            currentPose = obj.robotPose.getPose();
            obj.robotPosition = [currentPose(1),currentPose(2)];
        end
    end
end
