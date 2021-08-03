//
//  ViewController.swift
//  PingHelperExample
//
//  Created by Smart on 2021/8/3.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
 
    }


    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        PingHelper.ping(["114.114.114.114"], count: 2, timeout: 2) { result in
            print("== \(result.first?.delay ?? 0)")
        }
    }
}

